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

/// 捕获/恢复页内滚动：与 StablePDFView 左键平移相同，直接操作 NSClipView，不用 `go(to:on:)`。
private enum PDFViewportScroll {
    struct Parts {
        let scrollView: NSScrollView
        let clip: NSClipView
        let docView: NSView
    }

    static func readBandOffset(visibleHeight: CGFloat) -> CGFloat {
        min(120, max(visibleHeight * 0.12, 24))
    }

    static func parts(from pdfView: PDFView) -> Parts? {
        guard let scrollView = pdfView.subviews.compactMap({ $0 as? NSScrollView }).first,
              let docView = pdfView.documentView else { return nil }
        return Parts(scrollView: scrollView, clip: scrollView.contentView, docView: docView)
    }

    static func capturePageAnchor(from pdfView: PDFView, page: PDFPage) -> CGPoint? {
        guard let p = parts(from: pdfView) else { return nil }
        let visible = p.clip.documentVisibleRect
        let readBandY = visible.minY + readBandOffset(visibleHeight: visible.height)
        let docPoint = NSPoint(x: visible.midX, y: readBandY)
        let viewPoint = p.docView.convert(docPoint, to: pdfView)
        return pdfView.convert(viewPoint, to: page)
    }

    static func captureScrollOrigin(from pdfView: PDFView) -> NSPoint? {
        parts(from: pdfView)?.clip.bounds.origin
    }

    static func applyScrollOrigin(_ origin: NSPoint, in pdfView: PDFView) -> Bool {
        guard let p = parts(from: pdfView) else { return false }
        pdfView.layoutDocumentView()
        let constrained = p.clip.constrainScroll(origin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.clip.setBoundsOrigin(constrained)
        p.scrollView.reflectScrolledClipView(p.clip)
        CATransaction.commit()
        return true
    }

    @discardableResult
    static func restoreViewport(
        pagePoint: CGPoint,
        scrollOrigin: NSPoint?,
        on page: PDFPage,
        in pdfView: PDFView
    ) -> Bool {
        guard pdfView.currentPage === page else { return false }
        if let scrollOrigin, applyScrollOrigin(scrollOrigin, in: pdfView) {
            return true
        }
        return scrollToPageAnchor(pagePoint, on: page, in: pdfView)
    }

    @discardableResult
    static func scrollToPageAnchor(_ pagePoint: CGPoint, on page: PDFPage, in pdfView: PDFView) -> Bool {
        guard pdfView.currentPage === page, let p = parts(from: pdfView) else { return false }

        pdfView.layoutDocumentView()

        let viewPoint = pdfView.convert(pagePoint, from: page)
        let docPoint = p.docView.convert(viewPoint, from: pdfView)
        let visible = p.clip.bounds.size
        let readOffset = readBandOffset(visibleHeight: visible.height)
        let pageRect = pageRectInDocument(page, pdfView: pdfView, parts: p)

        var originX = docPoint.x - visible.width * 0.5
        if pageRect.width <= visible.width + 1 {
            originX = pageRect.midX - visible.width * 0.5
        }

        let origin = p.clip.constrainScroll(NSPoint(x: originX, y: docPoint.y - readOffset))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.clip.setBoundsOrigin(origin)
        p.scrollView.reflectScrolledClipView(p.clip)
        CATransaction.commit()
        return true
    }

    static func pageRectInDocument(_ page: PDFPage, pdfView: PDFView, parts: Parts) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)
        let inView = pdfView.convert(pageBounds, from: page)
        return parts.docView.convert(inView, from: pdfView)
    }

    /// 当前页在视口内是否还有可滚动的余量（避免整页适配高度时误拦截 PDFKit 翻页）。
    static func hasScrollableOverflow(in pdfView: PDFView) -> Bool {
        guard let p = parts(from: pdfView) else { return false }
        pdfView.layoutDocumentView()
        let docSize = p.docView.frame.size
        let visible = p.clip.bounds.size
        return docSize.height > visible.height + 2 || docSize.width > visible.width + 2
    }

    /// 将滚轮增量施加到 clip，返回未能消费的溢出量（用于边界累积翻页）。
    static func applyScrollDelta(
        deltaX: CGFloat,
        deltaY: CGFloat,
        in pdfView: PDFView
    ) -> (overflowX: CGFloat, overflowY: CGFloat) {
        guard let p = parts(from: pdfView) else { return (0, 0) }
        pdfView.layoutDocumentView()
        var origin = p.clip.bounds.origin
        origin.x += deltaX
        origin.y += deltaY
        let constrained = p.clip.constrainScroll(origin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.clip.setBoundsOrigin(constrained)
        p.scrollView.reflectScrolledClipView(p.clip)
        CATransaction.commit()
        return (origin.x - constrained.x, origin.y - constrained.y)
    }
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
    /// 在页顶/页底继续滚动时累积溢出，超过阈值才翻页，减轻触控板惯性误翻。
    private var pageTurnScrollAccumulator: CGFloat = 0
    private var pageTurnScrollAxis: PageTurnScrollAxis?
    /// 本次滚动手势的主导方向；上下滚动时忽略横向溢出，避免误触发左右翻页。
    private var scrollGestureDominantAxis: PageTurnScrollAxis?
    private var scrollGestureTotalDeltaX: CGFloat = 0
    private var scrollGestureTotalDeltaY: CGFloat = 0
    private static let pageTurnScrollThreshold: CGFloat = 96
    /// 横向翻页阈值更高，且需明显强于纵向分量。
    private static let horizontalPageTurnScrollThreshold: CGFloat = 144
    private static let horizontalDominanceRatio: CGFloat = 1.8

    private enum PageTurnScrollAxis {
        case vertical
        case horizontal
    }

    var onBoundsReadyForScale: (() -> Void)?
    var onViewportInteractionEnded: (() -> Void)?

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
        if bounds.width > 0, bounds.height > 0 {
            onBoundsReadyForScale?()
        }
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
            onViewportInteractionEnded?()
            return
        }
        super.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) {
            resetScrollGestureState()
        }

        guard PDFViewportScroll.hasScrollableOverflow(in: self) else {
            resetScrollGestureState()
            super.scrollWheel(with: event)
            onViewportInteractionEnded?()
            return
        }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        let deltaX = event.scrollingDeltaX * multiplier
        let deltaY = event.scrollingDeltaY * multiplier

        if abs(deltaX) < 0.01, abs(deltaY) < 0.01 {
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                resetScrollGestureState()
            }
            return
        }

        updateScrollGestureDominantAxis(deltaX: deltaX, deltaY: deltaY)

        let overflow = PDFViewportScroll.applyScrollDelta(deltaX: deltaX, deltaY: deltaY, in: self)

        if abs(overflow.overflowY) >= 0.5 {
            if tryTurnPageForVerticalOverflow(overflow.overflowY) {
                onViewportInteractionEnded?()
                return
            }
        } else if abs(overflow.overflowX) >= 0.5, shouldAllowHorizontalPageTurn(for: overflow) {
            if tryTurnPageForHorizontalOverflow(overflow.overflowX) {
                onViewportInteractionEnded?()
                return
            }
        } else {
            resetPageTurnScrollAccumulator()
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            resetScrollGestureState()
        }

        onViewportInteractionEnded?()
    }

    private func resetPageTurnScrollAccumulator() {
        pageTurnScrollAccumulator = 0
        pageTurnScrollAxis = nil
    }

    private func resetScrollGestureState() {
        resetPageTurnScrollAccumulator()
        scrollGestureDominantAxis = nil
        scrollGestureTotalDeltaX = 0
        scrollGestureTotalDeltaY = 0
    }

    private func updateScrollGestureDominantAxis(deltaX: CGFloat, deltaY: CGFloat) {
        scrollGestureTotalDeltaX += abs(deltaX)
        scrollGestureTotalDeltaY += abs(deltaY)

        let totalX = scrollGestureTotalDeltaX
        let totalY = scrollGestureTotalDeltaY
        guard totalX >= 8 || totalY >= 8 else { return }

        if totalY >= totalX * Self.horizontalDominanceRatio {
            scrollGestureDominantAxis = .vertical
        } else if totalX >= totalY * Self.horizontalDominanceRatio {
            scrollGestureDominantAxis = .horizontal
        }
    }

    /// 上下滚动时页面宽度常已适配视口，横向 delta 无法被消费；仅在明确横向手势时才允许左右翻页。
    private func shouldAllowHorizontalPageTurn(for overflow: (overflowX: CGFloat, overflowY: CGFloat)) -> Bool {
        if scrollGestureDominantAxis == .vertical { return false }

        let absX = abs(overflow.overflowX)
        let absY = abs(overflow.overflowY)
        if absY >= 0.5, absX < absY * Self.horizontalDominanceRatio { return false }

        if scrollGestureDominantAxis == nil {
            let totalX = scrollGestureTotalDeltaX
            let totalY = scrollGestureTotalDeltaY
            if totalY > totalX { return false }
            if totalX < Self.horizontalPageTurnScrollThreshold * 0.35 { return false }
        }

        return true
    }

    private func tryTurnPageForVerticalOverflow(_ overflowY: CGFloat) -> Bool {
        accumulatePageTurnOverflow(
            overflowY,
            axis: .vertical,
            threshold: Self.pageTurnScrollThreshold
        )
    }

    private func tryTurnPageForHorizontalOverflow(_ overflowX: CGFloat) -> Bool {
        accumulatePageTurnOverflow(
            overflowX,
            axis: .horizontal,
            threshold: Self.horizontalPageTurnScrollThreshold
        )
    }

    private func accumulatePageTurnOverflow(
        _ overflow: CGFloat,
        axis: PageTurnScrollAxis,
        threshold: CGFloat
    ) -> Bool {
        guard overflow != 0 else {
            resetPageTurnScrollAccumulator()
            return false
        }
        if pageTurnScrollAxis != axis {
            pageTurnScrollAxis = axis
            pageTurnScrollAccumulator = 0
        }
        if pageTurnScrollAccumulator != 0,
           (pageTurnScrollAccumulator > 0) != (overflow > 0) {
            pageTurnScrollAccumulator = overflow
        } else {
            pageTurnScrollAccumulator += overflow
        }

        guard abs(pageTurnScrollAccumulator) >= threshold else { return false }

        let towardNext = pageTurnScrollAccumulator < 0
        resetPageTurnScrollAccumulator()
        return turnPage(towardNext: towardNext)
    }

    @discardableResult
    private func turnPage(towardNext: Bool) -> Bool {
        guard let doc = document, let page = currentPage else { return false }
        let idx = doc.index(for: page)
        guard idx != NSNotFound else { return false }
        let target = towardNext ? idx + 1 : idx - 1
        guard target >= 0, target < doc.pageCount, let targetPage = doc.page(at: target) else {
            return false
        }
        go(to: targetPage)
        return true
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
    var scaleApplyToken: UUID
    var currentPage: Int
    var viewportAnchor: CGPoint?
    var viewportScrollOrigin: CGPoint?
    var viewportRestoreToken: UUID
    var onPageChange: (Int) -> Void
    var onDocumentLoaded: (Int) -> Void
    var onScaleChange: (CGFloat, Bool) -> Void
    var onViewportCapture: (Int, CGFloat?, CGFloat?, CGFloat, CGFloat?, CGFloat?) -> Void
    var onPersistViewportSnapshot: (Int, CGFloat, CGFloat, CGFloat, CGFloat?, CGFloat?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPageChange: onPageChange,
            onDocumentLoaded: onDocumentLoaded,
            onScaleChange: onScaleChange,
            onViewportCapture: onViewportCapture,
            onPersistViewportSnapshot: onPersistViewportSnapshot
        )
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = StablePDFView()
        pdfView.backgroundColor = theme.pdfReaderChromeNSColor
        pdfView.autoScales = false
        pdfView.displayMode = spreadMode
        pdfView.displayDirection = .vertical
        pdfView.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        pdfView.onBoundsReadyForScale = { [weak coordinator = context.coordinator] in
            coordinator?.retryPendingScaleApplyIfNeeded()
            coordinator?.retryPendingViewportRestoreIfNeeded()
        }
        context.coordinator.pdfView = pdfView
        context.coordinator.scaleMode = scaleMode
        context.coordinator.customScale = customScale
        wireViewportCallbacks(on: pdfView, coordinator: context.coordinator)
        pdfView.alphaValue = viewportAnchor != nil ? 0 : 1
        if let doc = document {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pdfView.document = doc
            if currentPage >= 1, currentPage <= doc.pageCount,
               let page = doc.page(at: currentPage - 1) {
                pdfView.go(to: page)
            }
            _ = context.coordinator.consumeViewportRestoreToken(viewportRestoreToken)
            if let viewportAnchor {
                context.coordinator.scheduleViewportRestore(
                    anchor: viewportAnchor,
                    scrollOrigin: viewportScrollOrigin
                )
            }
            context.coordinator.invalidateAppliedScaleCache()
            context.coordinator.markScaleApplyPending()
            context.coordinator.tryApplyPendingScale(
                pdfView: pdfView,
                mode: scaleMode,
                custom: customScale,
                force: true
            )
            context.coordinator.notifyDocument(doc)
            if let page = pdfView.currentPage {
                context.coordinator.tryRestoreScheduledViewport(on: pdfView, page: page)
            }
            CATransaction.commit()
        }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: pdfView
        )
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        context.coordinator.onDocumentLoaded = onDocumentLoaded
        context.coordinator.onScaleChange = onScaleChange
        context.coordinator.onViewportCapture = onViewportCapture
        context.coordinator.onPersistViewportSnapshot = onPersistViewportSnapshot
        context.coordinator.scaleMode = scaleMode
        context.coordinator.customScale = customScale
        pdfView.backgroundColor = theme.pdfReaderChromeNSColor
        wireViewportCallbacks(on: pdfView, coordinator: context.coordinator)
        if pdfView.document !== document {
            pdfView.document = document
            context.coordinator.resetScaleApplicationState()
            context.coordinator.markDocumentChanged()
            if let doc = document {
                context.coordinator.notifyDocument(doc)
            }
        }
        if pdfView.displayMode != spreadMode {
            pdfView.displayMode = spreadMode
        }

        let documentChanged = context.coordinator.consumeDocumentChanged()
        let scaleTokenChanged = context.coordinator.consumeScaleApplyToken(scaleApplyToken)
        let forceScaleApply = documentChanged || scaleTokenChanged
        if forceScaleApply {
            context.coordinator.invalidateAppliedScaleCache()
            context.coordinator.markScaleApplyPending()
        }
        guard let doc = pdfView.document, currentPage >= 1, currentPage <= doc.pageCount,
              let page = doc.page(at: currentPage - 1) else { return }

        let navigatedToPage = pdfView.currentPage != page
        if navigatedToPage {
            if viewportAnchor != nil {
                pdfView.alphaValue = 0
            }
            pdfView.go(to: page)
        }

        if context.coordinator.consumeViewportRestoreToken(viewportRestoreToken), let viewportAnchor {
            pdfView.alphaValue = 0
            context.coordinator.scheduleViewportRestore(
                anchor: viewportAnchor,
                scrollOrigin: viewportScrollOrigin
            )
        }

        context.coordinator.tryApplyPendingScale(
            pdfView: pdfView,
            mode: scaleMode,
            custom: customScale,
            force: forceScaleApply
        )

        if navigatedToPage, viewportAnchor == nil {
            context.coordinator.scrollToTop(of: page, on: pdfView)
            pdfView.alphaValue = 1
            context.coordinator.focusReader()
        } else if viewportAnchor == nil, !context.coordinator.hasPendingViewportRestore {
            pdfView.alphaValue = 1
            context.coordinator.focusReader()
        }
        context.coordinator.tryRestoreScheduledViewport(on: pdfView, page: page)
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.cancelPendingViewportCapture()
        coordinator.captureViewportImmediately(from: nsView, persistToDisk: true)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: nsView)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewScaleChanged, object: nsView)
    }

    private func wireViewportCallbacks(on pdfView: PDFView, coordinator: Coordinator) {
        guard let stable = pdfView as? StablePDFView else { return }
        stable.onViewportInteractionEnded = { [weak coordinator, weak pdfView] in
            guard let coordinator, let pdfView else { return }
            coordinator.scheduleViewportCapture(from: pdfView)
        }
    }

    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        var onPageChange: (Int) -> Void
        var onDocumentLoaded: (Int) -> Void
        var onScaleChange: (CGFloat, Bool) -> Void
        var onViewportCapture: (Int, CGFloat?, CGFloat?, CGFloat, CGFloat?, CGFloat?) -> Void
        var onPersistViewportSnapshot: (Int, CGFloat, CGFloat, CGFloat, CGFloat?, CGFloat?) -> Void
        var scaleMode: PDFKitViewModel.ScaleMode = .fitHeight
        var customScale: CGFloat = 1.0
        private var lastAppliedScaleMode: PDFKitViewModel.ScaleMode?
        private var lastAppliedScaleFactor: CGFloat?
        private var suppressScaleNotification = false
        private var documentChangedPending = false
        private var pendingScaleApply = false
        private var lastScaleApplyToken: UUID?
        private var pendingViewportAnchor: CGPoint?
        private var pendingScrollOrigin: NSPoint?
        private var lastViewportRestoreToken: UUID?
        private var viewportCaptureWorkItem: DispatchWorkItem?

        init(
            onPageChange: @escaping (Int) -> Void,
            onDocumentLoaded: @escaping (Int) -> Void,
            onScaleChange: @escaping (CGFloat, Bool) -> Void,
            onViewportCapture: @escaping (Int, CGFloat?, CGFloat?, CGFloat, CGFloat?, CGFloat?) -> Void,
            onPersistViewportSnapshot: @escaping (Int, CGFloat, CGFloat, CGFloat, CGFloat?, CGFloat?) -> Void
        ) {
            self.onPageChange = onPageChange
            self.onDocumentLoaded = onDocumentLoaded
            self.onScaleChange = onScaleChange
            self.onViewportCapture = onViewportCapture
            self.onPersistViewportSnapshot = onPersistViewportSnapshot
        }

        func notifyDocument(_ doc: PDFDocument) {
            onDocumentLoaded(doc.pageCount)
            if pendingViewportAnchor == nil {
                focusReader()
            }
        }

        /// 打开文件后把焦点交给阅读区；页码框已禁止自动 first responder，无需与 TextField 抢焦点。
        func focusReader() {
            guard let pdfView else { return }
            let assign = {
                _ = pdfView.window?.makeFirstResponder(pdfView)
            }
            if pdfView.window != nil {
                assign()
            } else {
                DispatchQueue.main.async { assign() }
            }
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pv = pdfView, let page = pv.currentPage, let doc = pv.document else { return }
            let idx = doc.index(for: page)
            if idx != NSNotFound {
                onPageChange(idx + 1)
            }
            scheduleViewportCapture(from: pv)
        }

        @objc func scaleChanged(_ notification: Notification) {
            guard !suppressScaleNotification, let pv = pdfView else { return }
            onScaleChange(pv.scaleFactor, true)
            scheduleViewportCapture(from: pv)
        }

        func markDocumentChanged() {
            documentChangedPending = true
        }

        func consumeDocumentChanged() -> Bool {
            let changed = documentChangedPending
            documentChangedPending = false
            return changed
        }

        func consumeScaleApplyToken(_ token: UUID) -> Bool {
            guard lastScaleApplyToken != token else { return false }
            lastScaleApplyToken = token
            return true
        }

        func consumeViewportRestoreToken(_ token: UUID) -> Bool {
            guard lastViewportRestoreToken != token else { return false }
            lastViewportRestoreToken = token
            return true
        }

        var hasPendingViewportRestore: Bool { pendingViewportAnchor != nil }

        func scheduleViewportRestore(anchor: CGPoint?, scrollOrigin: CGPoint?) {
            pendingViewportAnchor = anchor
            if let scrollOrigin {
                pendingScrollOrigin = NSPoint(x: scrollOrigin.x, y: scrollOrigin.y)
            } else {
                pendingScrollOrigin = nil
            }
        }

        func invalidateAppliedScaleCache() {
            lastAppliedScaleMode = nil
            lastAppliedScaleFactor = nil
        }

        func resetScaleApplicationState() {
            invalidateAppliedScaleCache()
            pendingScaleApply = false
            lastScaleApplyToken = nil
            pendingViewportAnchor = nil
            pendingScrollOrigin = nil
        }

        func markScaleApplyPending() {
            pendingScaleApply = true
        }

        func tryApplyPendingScale(
            pdfView: PDFView,
            mode: PDFKitViewModel.ScaleMode,
            custom: CGFloat,
            force: Bool = false
        ) {
            guard pendingScaleApply else { return }
            if applyScale(pdfView: pdfView, mode: mode, custom: custom, force: force) {
                pendingScaleApply = false
                if let page = pdfView.currentPage {
                    tryRestoreScheduledViewport(on: pdfView, page: page)
                }
            }
        }

        func retryPendingScaleApplyIfNeeded() {
            guard pendingScaleApply, let pdfView else { return }
            tryApplyPendingScale(
                pdfView: pdfView,
                mode: scaleMode,
                custom: customScale,
                force: true
            )
        }

        func retryPendingViewportRestoreIfNeeded() {
            guard pendingViewportAnchor != nil, let pdfView, let page = pdfView.currentPage else { return }
            tryRestoreScheduledViewport(on: pdfView, page: page)
        }

        func tryRestoreScheduledViewport(on pdfView: PDFView, page: PDFPage) {
            guard pendingViewportAnchor != nil else { return }
            guard pdfView.bounds.width > 0, pdfView.bounds.height > 0 else { return }
            guard !pendingScaleApply else { return }
            guard pdfView.currentPage === page else { return }
            guard let anchor = pendingViewportAnchor else { return }
            let scrollOrigin = pendingScrollOrigin
            guard PDFViewportScroll.restoreViewport(
                pagePoint: anchor,
                scrollOrigin: scrollOrigin,
                on: page,
                in: pdfView
            ) else { return }
            pendingViewportAnchor = nil
            pendingScrollOrigin = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pdfView.alphaValue = 1
            CATransaction.commit()
            focusReader()
        }

        func cancelPendingViewportCapture() {
            viewportCaptureWorkItem?.cancel()
            viewportCaptureWorkItem = nil
        }

        func scheduleViewportCapture(from pdfView: PDFView) {
            cancelPendingViewportCapture()
            let item = DispatchWorkItem { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                self.captureViewportImmediately(from: pdfView)
            }
            viewportCaptureWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }

        /// 同步读取视口；回调推到下一轮 RunLoop，避免在 SwiftUI dismantle / 更新周期内修改 @Published 崩溃。
        func captureViewportImmediately(from pdfView: PDFView, persistToDisk: Bool = false) {
            guard let page = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let idx = doc.index(for: page)
            guard idx != NSNotFound,
                  let pagePoint = PDFViewportScroll.capturePageAnchor(from: pdfView, page: page) else { return }
            let scrollOrigin = PDFViewportScroll.captureScrollOrigin(from: pdfView)

            if persistToDisk {
                onPersistViewportSnapshot(
                    idx + 1,
                    pagePoint.x,
                    pagePoint.y,
                    pdfView.scaleFactor,
                    scrollOrigin?.x,
                    scrollOrigin?.y
                )
            }
            deliverViewportCapture(
                page: idx + 1,
                anchorX: pagePoint.x,
                anchorY: pagePoint.y,
                scale: pdfView.scaleFactor,
                scrollOriginX: scrollOrigin?.x,
                scrollOriginY: scrollOrigin?.y
            )
        }

        private func deliverViewportCapture(
            page: Int,
            anchorX: CGFloat,
            anchorY: CGFloat,
            scale: CGFloat,
            scrollOriginX: CGFloat?,
            scrollOriginY: CGFloat?
        ) {
            let handler = onViewportCapture
            DispatchQueue.main.async {
                handler(page, anchorX, anchorY, scale, scrollOriginX, scrollOriginY)
            }
        }

        func scrollToTop(of pinnedPage: PDFPage, on pdfView: PDFView) {
            guard let current = pdfView.currentPage, current === pinnedPage,
                  let p = PDFViewportScroll.parts(from: pdfView) else { return }
            pdfView.layoutDocumentView()
            let pageBounds = pinnedPage.bounds(for: .mediaBox)
            let bandH = min(80, max(pageBounds.height * 0.2, 24))
            let topBand = CGRect(x: pageBounds.minX, y: pageBounds.maxY - bandH, width: pageBounds.width, height: bandH)
            let viewRect = pdfView.convert(topBand, from: pinnedPage)
            let docRect = p.docView.convert(viewRect, from: pdfView)
            let visible = p.clip.bounds.size
            var originX = docRect.midX - visible.width * 0.5
            let pageRect = PDFViewportScroll.pageRectInDocument(pinnedPage, pdfView: pdfView, parts: p)
            if pageRect.width <= visible.width + 1 {
                originX = pageRect.midX - visible.width * 0.5
            }
            let origin = p.clip.constrainScroll(NSPoint(x: originX, y: docRect.minY))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            p.clip.setBoundsOrigin(origin)
            p.scrollView.reflectScrolledClipView(p.clip)
            CATransaction.commit()
        }

        @discardableResult
        func applyScale(
            pdfView: PDFView,
            mode: PDFKitViewModel.ScaleMode,
            custom: CGFloat,
            force: Bool = false
        ) -> Bool {
            guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return false }
            let pageRect = page.bounds(for: .mediaBox)
            let viewSize = pdfView.bounds.size
            guard pageRect.width > 0, pageRect.height > 0, viewSize.width > 0, viewSize.height > 0 else {
                return false
            }

            let targetScale: CGFloat
            switch mode {
            case .fitWidth:
                targetScale = min(max((viewSize.width - 48) / pageRect.width, 0.05), 10)
            case .fitHeight:
                targetScale = min(max((viewSize.height - 48) / pageRect.height, 0.05), 10)
            case .custom:
                targetScale = min(max(custom, 0.05), 10)
            }

            if lastAppliedScaleMode == mode,
               let last = lastAppliedScaleFactor,
               abs(last - targetScale) < 0.001,
               abs(pdfView.scaleFactor - targetScale) < 0.001 {
                return true
            }

            let previousMode = lastAppliedScaleMode

            suppressScaleNotification = true
            pdfView.scaleFactor = targetScale
            suppressScaleNotification = false

            lastAppliedScaleMode = mode
            lastAppliedScaleFactor = targetScale
            onScaleChange(targetScale, false)

            if pendingViewportAnchor == nil {
                if mode == .fitWidth, previousMode == .fitHeight {
                    scrollToTop(of: page, on: pdfView)
                } else if mode == .fitHeight, previousMode == .fitWidth {
                    scrollToTop(of: page, on: pdfView)
                }
            }
            return true
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

    /// 返回不超过 `page` 的最近一级大纲标题（用于书签所在目录）。
    static func title(forPage page: Int, in outline: [PDFOutlineEntry]) -> String? {
        outline.filter { $0.page <= page }.max(by: { $0.page < $1.page })?.title
    }
}
