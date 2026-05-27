//
//  PDFKitReaderView.swift
//  PDF-Reader
//

import AppKit
import PDFKit
import QuartzCore
import SwiftUI

/// AppKit 在部分 SDK / Swift 模式下未导出 `NSImmediateActionGestureRecognizer` 符号，运行时按类名识别。
private let kImmediateActionGestureClass: AnyClass? =
    NSClassFromString("NSImmediateActionGestureRecognizer")

private func isImmediateActionGestureRecognizer(_ gr: NSGestureRecognizer) -> Bool {
    guard let cls = kImmediateActionGestureClass else { return false }
    return gr.isKind(of: cls)
}

/// 新版 macOS 上部分 PDF 在 PDFKit 默认「文本选择 / Lookup / 右键菜单查词」路径会触发
/// CoreGraphics `PageLayout::getWordRange` SIGILL。
/// 1) 拒绝并剥离 `NSImmediateActionGestureRecognizer`（事件仍会经 `_sendMouseEventToGestureRecognizers` 走到
///    `-[PDFView immediateActionRecognizerWillPrepare:]`，仅改 mouseDown 不够）。
/// 2) 左键不再调用 `super.mouseDown`，避免进入 `trackStandardTextSelection`；左键拖动用内容区平移代替。
/// 3) 覆盖 `menu(for:)`，禁止 PDFKit 默认右键菜单（`rvItemAtPoint` → `selectionFromPoint` 同样会 SIGILL）。
private final class StablePDFView: PDFView {
    private var isPanning = false
    private var lastMouseInWindow = NSPoint.zero

    /// AppKit `PDFView` 未在 Swift 中公开 `scrollView`；内嵌的 `NSScrollView` 通常为首个子视图。
    private var embeddedClipView: NSClipView? {
        subviews.compactMap { ($0 as? NSScrollView)?.contentView }.first
    }

    /// `PDFView` 可能在自身或内嵌 document 视图上注册 Immediate Action；递归剥离以免漏网。
    private func removeImmediateActionGestureRecognizers(from root: NSView, depth: Int = 0) {
        guard depth < 32 else { return }
        for gr in Array(root.gestureRecognizers) where isImmediateActionGestureRecognizer(gr) {
            root.removeGestureRecognizer(gr)
        }
        for child in root.subviews {
            removeImmediateActionGestureRecognizers(from: child, depth: depth + 1)
        }
    }

    override func addGestureRecognizer(_ gestureRecognizer: NSGestureRecognizer) {
        if isImmediateActionGestureRecognizer(gestureRecognizer) { return }
        super.addGestureRecognizer(gestureRecognizer)
    }

    override func layout() {
        super.layout()
        removeImmediateActionGestureRecognizers(from: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showSafeContextMenu(for: event)
            return
        }
        window?.makeFirstResponder(self)
        isPanning = true
        lastMouseInWindow = event.locationInWindow
    }

    override func rightMouseDown(with event: NSEvent) {
        showSafeContextMenu(for: event)
    }

    /// 不调用 `super.menu(for:)`，避免 PDFKit 在 `menuForEvent:` 里走 `rvItemAtPoint`。
    override func menu(for event: NSEvent) -> NSMenu? {
        makeSafeContextMenu()
    }

    private func showSafeContextMenu(for event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func makeSafeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let zoomIn = NSMenuItem(title: "放大", action: #selector(zoomInFromMenu(_:)), keyEquivalent: "+")
        zoomIn.target = self
        menu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "缩小", action: #selector(zoomOutFromMenu(_:)), keyEquivalent: "-")
        zoomOut.target = self
        menu.addItem(zoomOut)
        menu.addItem(.separator())
        let fitWidth = NSMenuItem(title: "适应宽度", action: #selector(fitWidthFromMenu(_:)), keyEquivalent: "")
        fitWidth.target = self
        menu.addItem(fitWidth)
        return menu
    }

    @objc private func zoomInFromMenu(_ sender: Any?) {
        scaleFactor = min(scaleFactor * 1.25, 10)
    }

    @objc private func zoomOutFromMenu(_ sender: Any?) {
        scaleFactor = max(scaleFactor / 1.25, 0.05)
    }

    @objc private func fitWidthFromMenu(_ sender: Any?) {
        guard let page = currentPage ?? document?.page(at: 0) else { return }
        let pageRect = page.bounds(for: .mediaBox)
        let viewSize = bounds.size
        guard pageRect.width > 0, viewSize.width > 0 else { return }
        scaleFactor = min(max((viewSize.width - 48) / pageRect.width, 0.05), 10)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning, let clip = embeddedClipView else {
            super.mouseDragged(with: event)
            return
        }
        let cur = event.locationInWindow
        let dx = cur.x - lastMouseInWindow.x
        let dy = cur.y - lastMouseInWindow.y
        lastMouseInWindow = cur
        var o = clip.bounds.origin
        o.x -= dx
        o.y -= dy
        clip.setBoundsOrigin(o)
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            return
        }
        super.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
    }
}

struct PDFKitReaderView: NSViewRepresentable {
    @Binding var document: PDFDocument?
    var theme: AppTheme
    var spreadMode: PDFDisplayMode
    var scaleMode: PDFKitViewModel.ScaleMode
    var customScale: CGFloat
    var currentPage: Int
    var onPageChange: (Int) -> Void
    var onDocumentLoaded: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange, onDocumentLoaded: onDocumentLoaded)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = StablePDFView()
        pdfView.backgroundColor = theme.pdfReaderChromeNSColor
        pdfView.autoScales = false
        pdfView.displayMode = spreadMode
        pdfView.displayDirection = .vertical
        pdfView.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        context.coordinator.pdfView = pdfView
        if let doc = document {
            pdfView.document = doc
            context.coordinator.applyScale(pdfView: pdfView, mode: scaleMode, custom: customScale)
            context.coordinator.notifyDocument(doc)
        }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        context.coordinator.onDocumentLoaded = onDocumentLoaded
        pdfView.backgroundColor = theme.pdfReaderChromeNSColor
        if pdfView.document !== document {
            pdfView.document = document
            if let doc = document {
                context.coordinator.notifyDocument(doc)
            }
        }
        if pdfView.displayMode != spreadMode {
            pdfView.displayMode = spreadMode
        }
        context.coordinator.applyScale(pdfView: pdfView, mode: scaleMode, custom: customScale)
        guard let doc = pdfView.document, currentPage >= 1, currentPage <= doc.pageCount,
              let page = doc.page(at: currentPage - 1) else { return }
        if pdfView.currentPage != page {
            pdfView.go(to: page)
            context.coordinator.scrollToTop(of: page, on: pdfView)
        }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: nsView)
    }

    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        var onPageChange: (Int) -> Void
        var onDocumentLoaded: (Int) -> Void
        /// 用于在「适应高度 → 适应宽度」时把滚动位置收到页顶，避免仍停在页中。
        private var lastAppliedScaleMode: PDFKitViewModel.ScaleMode?

        init(onPageChange: @escaping (Int) -> Void, onDocumentLoaded: @escaping (Int) -> Void) {
            self.onPageChange = onPageChange
            self.onDocumentLoaded = onDocumentLoaded
        }

        func notifyDocument(_ doc: PDFDocument) {
            onDocumentLoaded(doc.pageCount)
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pv = pdfView, let page = pv.currentPage, let doc = pv.document else { return }
            let idx = doc.index(for: page)
            if idx != NSNotFound {
                onPageChange(idx + 1)
            }
        }

        /// 将视口对齐到指定页顶部（与 `currentPage` 一致时才执行，避免误滚）。
        /// 使用同步布局 + 关闭隐式动画，避免「适应高度 → 适应宽度」时先显示页中再闪回页顶。
        func scrollToTop(of pinnedPage: PDFPage, on pdfView: PDFView) {
            guard let current = pdfView.currentPage, current === pinnedPage else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pdfView.layoutDocumentView()
            let b = pinnedPage.bounds(for: .mediaBox)
            let bandH = min(80, max(b.height * 0.2, 24))
            let topBand = CGRect(x: b.minX, y: b.maxY - bandH, width: b.width, height: bandH)
            pdfView.go(to: topBand, on: pinnedPage)
            CATransaction.commit()
        }

        func applyScale(pdfView: PDFView, mode: PDFKitViewModel.ScaleMode, custom: CGFloat) {
            guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
            let pageRect = page.bounds(for: .mediaBox)
            let viewSize = pdfView.bounds.size
            guard pageRect.width > 0, pageRect.height > 0, viewSize.width > 0, viewSize.height > 0 else { return }

            let previousMode = lastAppliedScaleMode

            switch mode {
            case .fitWidth:
                let s = (viewSize.width - 48) / pageRect.width
                pdfView.scaleFactor = min(max(s, 0.05), 10)
            case .fitHeight:
                let s = (viewSize.height - 48) / pageRect.height
                pdfView.scaleFactor = min(max(s, 0.05), 10)
            case .custom:
                pdfView.scaleFactor = min(max(custom, 0.25), 5.0)
            }

            lastAppliedScaleMode = mode

            if mode == .fitWidth, previousMode == .fitHeight {
                scrollToTop(of: page, on: pdfView)
            }
        }
    }
}

enum PDFKitViewModel {
    enum ScaleMode {
        case fitWidth
        case fitHeight
        case custom
    }
}

struct PDFOutlineEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let page: Int
}

enum PDFOutlineFlat {
    static func flatten(_ outline: PDFOutline?, document: PDFDocument) -> [PDFOutlineEntry] {
        var rows: [PDFOutlineEntry] = []
        func walk(_ item: PDFOutline?) {
            guard let item else { return }
            if let label = item.label, let dest = item.destination, let page = dest.page {
                let idx = document.index(for: page)
                if idx != NSNotFound {
                    rows.append(PDFOutlineEntry(title: label, page: idx + 1))
                }
            } else if let label = item.label, item.destination == nil {
                if let action = item.action as? PDFActionGoTo {
                    let dest = action.destination
                    if let page = dest.page {
                        let idx = document.index(for: page)
                        if idx != NSNotFound {
                            rows.append(PDFOutlineEntry(title: label, page: idx + 1))
                        }
                    }
                }
            }
            for i in 0..<item.numberOfChildren {
                walk(item.child(at: i))
            }
        }
        walk(outline)
        return rows
    }
}
