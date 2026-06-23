//
//  ReaderViewModel.swift
//  PDF-Reader
//

import Combine
import AppKit
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfEntry: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
}

struct ShelfHistoryEntry: Hashable {
    let path: String
    let exists: Bool
}

@MainActor
final class ReaderViewModel: ObservableObject {
    enum Mode: Equatable {
        case welcome
        case shelf
        case pdf
        case epub
    }

    private static let maxShelfHistory = 30

    enum ReaderSidebarTab {
        case toc
        case bookmarks
    }

    @Published var uiTheme: AppTheme = .midnight
    @Published var mode: Mode = .welcome

    @Published var shelfFolderPath: String?
    @Published var shelfTitle: String = "书架"
    @Published var shelfEntries: [ShelfEntry] = []

    @Published var currentFilePath: String?
    @Published var currentFileName: String = ""

    @Published var pdfDocument: PDFDocument?
    @Published var pdfOutline: [PDFOutlineEntry] = []
    @Published var pdfSpreadDouble: Bool = false
    @Published var pdfScaleMode: PDFKitViewModel.ScaleMode = .fitHeight
    @Published var pdfCustomScale: CGFloat = 1.0
    @Published var pdfScaleApplyToken = UUID()
    @Published var pdfCurrentPage: Int = 1
    @Published var pdfTotalPages: Int = 0
    @Published var pdfViewportAnchor: CGPoint?
    @Published var pdfScrollOrigin: CGPoint?
    @Published var pdfViewportRestoreToken = UUID()

    @Published var epubSession: EpubLoadSession?
    @Published var epubFontPercent: Int = 110
    @Published var epubDisplayedPage: Int?
    @Published var epubDisplayedTotal: Int?
    @Published var currentEpubCfi: String?
    @Published var currentEpubSpineIndex: Int?

    @Published var zoomFieldText: String = "100%"

    @Published var statusText: String = "就绪"
    @Published var showingSettings = false
    @Published var activeSidebar: ReaderSidebarTab?
    @Published var showingBookmarkPrompt = false
    @Published var bookmarkPromptDefault: String = ""
    @Published var bookmarkDraftLabel: String = ""

    @Published var bookmarks: [ReaderBookmark] = []
    @Published var tocJumpToken: UUID?
    @Published var tocJumpHref: String?
    @Published var bookmarkJumpToken: UUID?
    @Published var bookmarkJumpCfi: String?

    @Published var epubTocEntries: [EpubTocEntry] = []
    @Published var epubTocPull: UUID?
    @Published var epubBookmarkChapterPull: (token: UUID, cfi: String)?
    @Published var epubBookmarkBatchResolve: (token: UUID, cfis: [String])?
    @Published var epubStepToken: UUID?
    @Published var epubStepDelta: Int = 0

    @Published var shelfHistory: [ShelfHistoryEntry] = []

    private var persistence: AppPersistenceData
    private var coverCache: [String: NSImage] = [:]
    private var savePositionTask: Task<Void, Never>?
    private var saveSnapshotTask: Task<Void, Never>?
    /// 仅本次 App 运行有效：关窗再开恢复缩放/页内位置；退出 App 后自动清空。
    private var sessionPdfSnapshots: [String: PdfReadingSnapshot] = [:]
    private struct PendingBookmark {
        var label: String
        var path: String
        var cfi: String
        var page: Int?
        var spineIndex: Int?
    }
    private var pendingBookmark: PendingBookmark?

    var isBookmarkedHere: Bool {
        guard let path = currentFilePath else { return false }
        if mode == .epub {
            guard let cfi = currentEpubCfi else { return false }
            return bookmarks.contains { $0.cfi == cfi }
        }
        if mode == .pdf {
            return bookmarks.contains { $0.page == pdfCurrentPage }
        }
        return false
    }

    init() {
        persistence = AppPersistence.load()
        uiTheme = AppTheme.fromStorage(persistence.theme)
        pdfSpreadDouble = persistence.pdfSpreadMode == "double"
        shelfFolderPath = persistence.shelfFolder
        refreshShelfHistoryFromDisk()
        if let s = persistence.shelfFolder, FileManager.default.fileExists(atPath: s) {
            loadShelf(folder: URL(fileURLWithPath: s), pushHistory: false, save: false)
            mode = .shelf
        }
    }

    private func persist() {
        AppPersistence.save(persistence)
    }

    private func normalizePath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func refreshShelfHistoryFromDisk() {
        let excluded = Set(persistence.shelfHistoryExcluded.map { normalizePath($0) })
        var seen = Set<String>()
        var hist: [String] = []
        for raw in persistence.shelfFolderHistory {
            let p = normalizePath(raw)
            if p.isEmpty || excluded.contains(p) { continue }
            if seen.insert(p).inserted { hist.append(p) }
        }
        if let cur = persistence.shelfFolder.map({ normalizePath($0) }),
           !cur.isEmpty,
           !excluded.contains(cur) {
            hist.removeAll { $0 == cur }
            hist.insert(cur, at: 0)
        }
        if hist.count > Self.maxShelfHistory {
            hist = Array(hist.prefix(Self.maxShelfHistory))
        }
        shelfHistory = hist.map { ShelfHistoryEntry(path: $0, exists: FileManager.default.fileExists(atPath: $0)) }
    }

    private func pushShelfHistory(_ folderPath: String) {
        var p = normalizePath(folderPath)
        persistence.shelfHistoryExcluded.removeAll { normalizePath($0) == p }
        var h = persistence.shelfFolderHistory.map { normalizePath($0) }
        h.removeAll { $0 == p }
        h.insert(p, at: 0)
        if h.count > Self.maxShelfHistory {
            h = Array(h.prefix(Self.maxShelfHistory))
        }
        persistence.shelfFolderHistory = h
        persist()
        refreshShelfHistoryFromDisk()
    }

    func applyTheme(_ t: AppTheme) {
        uiTheme = t
        persistence.theme = t.rawValue
        persist()
    }

    func applyPdfSpread(double: Bool) {
        pdfSpreadDouble = double
        persistence.pdfSpreadMode = double ? "double" : "single"
        persist()
    }

    func setStatus(_ s: String) {
        statusText = s
    }

    func openChosenFile(url: URL) {
        let p = normalizePath(url.path)
        let name = url.lastPathComponent
        currentFilePath = p
        currentFileName = name
        let ext = url.pathExtension.lowercased()
        if ext == "epub" {
            openEpubFile(url: url)
        } else {
            openPdfFile(url: url)
        }
    }

    private func openPdfFile(url: URL) {
        guard let doc = PDFDocument(url: url) else {
            setStatus("无法打开 PDF")
            return
        }
        let key = normalizePath(url.path)
        pdfDocument = doc
        mode = .pdf
        pdfTotalPages = doc.pageCount
        loadPdfReadingState(for: key, pageCount: doc.pageCount)
        bookmarks = persistence.bookmarks[key] ?? []
        if let outline = doc.outlineRoot {
            pdfOutline = PDFOutlineFlat.flatten(outline, document: doc)
        } else {
            pdfOutline = []
        }
        updateZoomField()
        setStatus("已打开 · 共 \(pdfTotalPages) 页")
    }

    private func loadPdfReadingState(for key: String, pageCount: Int) {
        pdfViewportAnchor = nil
        pdfScrollOrigin = nil
        if let session = sessionPdfSnapshots[key] {
            applySessionPdfSnapshot(session, pageCount: pageCount)
            return
        }
        pdfScaleMode = .fitHeight
        pdfCustomScale = 1.0
        var start = 1
        if let saved = persistence.readingPositions[key], let page = saved.numberValue {
            start = max(1, Int(page))
        } else if let snap = persistence.pdfReadingSnapshots[key] {
            start = snap.page
        }
        pdfCurrentPage = min(max(1, start), max(1, pageCount))
        bumpPdfScaleApply()
    }

    private func applySessionPdfSnapshot(_ snap: PdfReadingSnapshot, pageCount: Int) {
        if let x = snap.anchorX, let y = snap.anchorY {
            pdfViewportAnchor = CGPoint(x: x, y: y)
        }
        if let x = snap.scrollOriginX, let y = snap.scrollOriginY {
            pdfScrollOrigin = CGPoint(x: x, y: y)
        }
        if let scale = snap.scale, scale > 0 {
            pdfCustomScale = CGFloat(scale)
            pdfScaleMode = pdfScaleMode(fromStorage: snap.scaleMode)
        } else {
            pdfScaleMode = .fitHeight
            pdfCustomScale = 1.0
        }
        pdfCurrentPage = min(max(1, snap.page), max(1, pageCount))
        if pdfViewportAnchor != nil || pdfScrollOrigin != nil {
            bumpPdfViewportRestore()
        }
        bumpPdfScaleApply()
    }

    private func currentPdfSessionSnapshot(page: Int) -> PdfReadingSnapshot {
        PdfReadingSnapshot(
            page: page,
            anchorX: pdfViewportAnchor.map { Double($0.x) },
            anchorY: pdfViewportAnchor.map { Double($0.y) },
            scale: Double(pdfCustomScale),
            scaleMode: pdfScaleModeStorageValue(pdfScaleMode),
            scrollOriginX: pdfScrollOrigin.map { Double($0.x) },
            scrollOriginY: pdfScrollOrigin.map { Double($0.y) }
        )
    }

    private func storeSessionPdfSnapshot(_ snap: PdfReadingSnapshot, key: String) {
        sessionPdfSnapshots[key] = snap
        persistence.readingPositions[key] = .double(Double(snap.page))
        persist()
    }

    private func pdfScaleMode(fromStorage value: String?) -> PDFKitViewModel.ScaleMode {
        switch value {
        case "fitWidth": return .fitWidth
        case "fitHeight": return .fitHeight
        default: return .custom
        }
    }

    private func pdfScaleModeStorageValue(_ mode: PDFKitViewModel.ScaleMode) -> String {
        switch mode {
        case .fitWidth: return "fitWidth"
        case .fitHeight: return "fitHeight"
        case .custom: return "custom"
        }
    }

    private func bumpPdfScaleApply() {
        pdfScaleApplyToken = UUID()
    }

    private func bumpPdfViewportRestore() {
        pdfViewportRestoreToken = UUID()
    }

    private func openEpubFile(url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            setStatus("读取 EPUB 失败")
            return
        }
        let key = normalizePath(url.path)
        mode = .epub
        let saved = persistence.readingPositions[key]?.stringValue
        epubSession = EpubLoadSession(id: UUID(), data: data, startCfi: saved)
        bookmarks = persistence.bookmarks[key] ?? []
        currentEpubCfi = saved
        currentEpubSpineIndex = nil
        epubFontPercent = 110
        updateZoomField()
        epubTocEntries = []
        setStatus("EPUB · \(url.lastPathComponent)")
    }

    func chooseOpenFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        var types: [UTType] = [.pdf]
        if let epub = UTType(filenameExtension: "epub") {
            types.append(epub)
        }
        p.allowedContentTypes = types
        if p.runModal() == .OK, let u = p.url {
            openChosenFile(url: u)
        }
    }

    func chooseShelfFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url {
            loadShelf(folder: u, pushHistory: true, save: true)
        }
    }

    func loadShelf(folder: URL, pushHistory: Bool, save: Bool) {
        let path = normalizePath(folder.path)
        shelfFolderPath = path
        shelfTitle = folder.lastPathComponent
        if save {
            persistence.shelfFolder = path
            persist()
        }
        if pushHistory { pushShelfHistory(path) }

        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        var rows: [ShelfEntry] = []
        for u in urls {
            let e = u.pathExtension.lowercased()
            if e != "pdf" && e != "epub" { continue }
            rows.append(ShelfEntry(url: u, name: u.lastPathComponent))
        }
        rows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        shelfEntries = rows
        mode = .shelf
        setStatus("书架: \(rows.count) 个图书文件")
    }

    func switchShelfHistory(path: String) {
        let n = normalizePath(path)
        guard FileManager.default.fileExists(atPath: n) else {
            setStatus("该路径已不存在")
            return
        }
        loadShelf(folder: URL(fileURLWithPath: n), pushHistory: true, save: true)
    }

    func removeShelfHistory(path: String) {
        let n = normalizePath(path)
        persistence.shelfFolderHistory.removeAll { normalizePath($0) == n }
        if !persistence.shelfHistoryExcluded.contains(n) {
            persistence.shelfHistoryExcluded.append(n)
            if persistence.shelfHistoryExcluded.count > 64 {
                persistence.shelfHistoryExcluded = Array(persistence.shelfHistoryExcluded.suffix(64))
            }
        }
        persist()
        refreshShelfHistoryFromDisk()
        setStatus("已从历史记录移除")
    }

    func backToShelf() {
        if shelfFolderPath != nil {
            mode = .shelf
            pdfDocument = nil
            epubSession = nil
            currentFilePath = nil
            setStatus("书架: \(shelfEntries.count) 个图书文件")
        } else {
            mode = .welcome
            setStatus("就绪")
        }
    }

    func handleDropped(url: URL) {
        openChosenFile(url: url)
    }

    func openShelfEntry(_ entry: ShelfEntry) {
        openChosenFile(url: entry.url)
    }

    func shelfCover(path: String) -> NSImage? {
        if let c = coverCache[path] { return c }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let image: NSImage?
        if ext == "pdf" {
            image = pdfFirstPageThumb(url: url)
        } else if ext == "epub" {
            image = EpubCoverExtractor.coverImage(epubURL: url)
        } else {
            image = nil
        }
        if let image { coverCache[path] = image }
        return image
    }

    private func pdfFirstPageThumb(url: URL) -> NSImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let r = page.bounds(for: .mediaBox)
        guard r.width > 0, r.height > 0 else { return nil }
        let tw: CGFloat = 100
        let th: CGFloat = 140
        let s = min(tw / r.width, th / r.height)
        let out = NSImage(size: NSSize(width: r.width * s, height: r.height * s))
        out.lockFocus()
        NSColor.white.set()
        NSBezierPath(rect: NSRect(origin: .zero, size: out.size)).fill()
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.scaleBy(x: s, y: s)
        page.draw(with: .mediaBox, to: ctx!)
        ctx?.restoreGState()
        out.unlockFocus()
        return out
    }

    func readingPercentForShelfPdf(path: String) -> Int? {
        let key = normalizePath(path)
        guard let v = persistence.readingPositions[key], let page = v.numberValue else { return nil }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        let total = max(1, doc.pageCount)
        return min(100, max(0, Int((page / Double(total)) * 100)))
    }

    func toggleToc() {
        if activeSidebar == .toc {
            activeSidebar = nil
        } else {
            showSidebar(.toc)
        }
    }

    func toggleBookmarks() {
        if activeSidebar == .bookmarks {
            activeSidebar = nil
        } else {
            showSidebar(.bookmarks)
        }
    }

    func showSidebar(_ tab: ReaderSidebarTab) {
        activeSidebar = tab
        if mode == .epub {
            if tab == .toc {
                epubTocPull = UUID()
            } else {
                epubTocPull = UUID()
                resolveEpubBookmarkTitlesIfNeeded()
            }
        }
    }

    func goPdfPage(_ page: Int) {
        pdfViewportAnchor = nil
        pdfScrollOrigin = nil
        bumpPdfViewportRestore()
        let t = min(max(1, page), max(1, pdfTotalPages))
        pdfCurrentPage = t
        scheduleSavePdfPosition()
    }

    func stepPdfPage(delta: Int) {
        let step = pdfSpreadDouble ? 2 : 1
        goPdfPage(pdfCurrentPage + delta * step)
    }

    func stepReading(delta: Int) {
        if mode == .epub {
            epubStepToken = UUID()
            epubStepDelta = delta < 0 ? -1 : 1
            return
        }
        stepPdfPage(delta: delta)
    }

    func pdfDisplayMode() -> PDFDisplayMode {
        pdfSpreadDouble ? .twoUp : .singlePage
    }

    func zoomIn() {
        if mode == .epub {
            epubFontPercent = min(220, epubFontPercent + 10)
            updateZoomField()
            return
        }
        pdfScaleMode = .custom
        pdfCustomScale = min(5.0, pdfCustomScale + 0.25)
        bumpPdfScaleApply()
        updateZoomField()
    }

    func zoomOut() {
        if mode == .epub {
            epubFontPercent = max(60, epubFontPercent - 10)
            updateZoomField()
            return
        }
        pdfScaleMode = .custom
        pdfCustomScale = max(0.25, pdfCustomScale - 0.25)
        bumpPdfScaleApply()
        updateZoomField()
    }

    func fitWidth() {
        if mode == .epub {
            epubFontPercent = 110
            updateZoomField()
            return
        }
        bumpPdfScaleApply()
        pdfScaleMode = .fitWidth
    }

    func fitHeight() {
        if mode == .epub {
            epubFontPercent = 110
            updateZoomField()
            return
        }
        bumpPdfScaleApply()
        pdfScaleMode = .fitHeight
    }

    /// 窗口重新打开时仅触发页内视口恢复；缩放已在内存/持久化中，勿重复 force 应用以免冲掉滚动位置。
    func refreshPdfScaleAfterWindowRestore() {
        guard mode == .pdf, pdfDocument != nil else { return }
        bumpPdfViewportRestore()
    }

    /// 窗口关闭或切后台时立即写入 PDF 阅读快照（避免 debounce 未落盘）。
    func flushPdfReadingSnapshot() {
        guard mode == .pdf, let path = currentFilePath else { return }
        saveSnapshotTask?.cancel()
        saveSnapshotTask = nil
        let key = normalizePath(path)
        storeSessionPdfSnapshot(currentPdfSessionSnapshot(page: pdfCurrentPage), key: key)
    }

    /// PDFView 实际缩放变化时同步工具栏百分比（双指缩放、适应宽/高等）。
    func syncPdfScaleFromReader(_ scale: CGFloat, userInitiated: Bool) {
        guard mode == .pdf else { return }
        let clamped = min(max(scale, 0.05), 10)
        let newText = "\(Int(round(clamped * 100)))%"

        if userInitiated {
            if pdfScaleMode != .custom {
                pdfScaleMode = .custom
            }
        } else if pdfScaleMode == .fitWidth || pdfScaleMode == .fitHeight {
            pdfScaleMode = .custom
        }
        if abs(pdfCustomScale - clamped) > 0.001 {
            pdfCustomScale = clamped
        }
        if zoomFieldText != newText {
            zoomFieldText = newText
        }
    }

    func applyZoomFieldEditingEnded() {
        let raw = zoomFieldText.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Double(raw), n > 0 else {
            updateZoomField()
            return
        }
        if mode == .epub {
            epubFontPercent = min(220, max(60, Int(round(n))))
            updateZoomField()
            return
        }
        if mode == .pdf {
            let clamped = min(500, max(25, n))
            pdfScaleMode = .custom
            pdfCustomScale = CGFloat(clamped / 100.0)
            bumpPdfScaleApply()
            updateZoomField()
        }
    }

    /// dismantle / 后台切换时直接写磁盘，不修改 @Published。
    func persistPdfSnapshotDirect(
        page: Int,
        anchorX: CGFloat,
        anchorY: CGFloat,
        scale: CGFloat,
        scrollOriginX: CGFloat? = nil,
        scrollOriginY: CGFloat? = nil
    ) {
        guard mode == .pdf, let path = currentFilePath else { return }
        let key = normalizePath(path)
        let clampedPage = min(max(1, page), max(1, pdfTotalPages))
        let snap = PdfReadingSnapshot(
            page: clampedPage,
            anchorX: Double(anchorX),
            anchorY: Double(anchorY),
            scale: Double(scale),
            scaleMode: pdfScaleModeStorageValue(pdfScaleMode),
            scrollOriginX: scrollOriginX.map { Double($0) },
            scrollOriginY: scrollOriginY.map { Double($0) }
        )
        storeSessionPdfSnapshot(snap, key: key)
    }

    func capturePdfViewport(
        page: Int,
        anchorX: CGFloat?,
        anchorY: CGFloat?,
        scale: CGFloat,
        scrollOriginX: CGFloat? = nil,
        scrollOriginY: CGFloat? = nil
    ) {
        let clampedPage = min(max(1, page), max(1, pdfTotalPages))
        let ax = anchorX
        let ay = anchorY
        let scaleValue = scale
        let originX = scrollOriginX
        let originY = scrollOriginY
        Task { @MainActor in
            guard mode == .pdf, let path = currentFilePath else { return }
            if let ax, let ay {
                pdfViewportAnchor = CGPoint(x: ax, y: ay)
            }
            if let originX, let originY {
                pdfScrollOrigin = CGPoint(x: originX, y: originY)
            }
            let key = normalizePath(path)
            saveSnapshotTask?.cancel()
            saveSnapshotTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                let snap = PdfReadingSnapshot(
                    page: clampedPage,
                    anchorX: ax.map { Double($0) },
                    anchorY: ay.map { Double($0) },
                    scale: Double(scaleValue),
                    scaleMode: pdfScaleModeStorageValue(pdfScaleMode),
                    scrollOriginX: originX.map { Double($0) },
                    scrollOriginY: originY.map { Double($0) }
                )
                storeSessionPdfSnapshot(snap, key: key)
            }
        }
    }

    func updateZoomField() {
        switch mode {
        case .epub:
            zoomFieldText = "\(epubFontPercent)%"
        case .pdf:
            zoomFieldText = "\(Int(round(pdfCustomScale * 100)))%"
        default:
            zoomFieldText = "100%"
        }
    }

    func scheduleSavePdfPosition() {
        guard let path = currentFilePath, mode == .pdf else { return }
        let key = normalizePath(path)
        let page = pdfCurrentPage
        savePositionTask?.cancel()
        savePositionTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            var snap = sessionPdfSnapshots[key] ?? currentPdfSessionSnapshot(page: page)
            snap.page = page
            storeSessionPdfSnapshot(snap, key: key)
        }
    }

    func saveEpubPosition(cfi: String) {
        guard let path = currentFilePath else { return }
        let key = normalizePath(path)
        currentEpubCfi = cfi
        persistence.readingPositions[key] = .string(cfi)
        persist()
    }

    func beginAddBookmark() {
        if mode == .epub {
            bookmarkPromptDefault = currentEpubChapterTitle() ?? "阅读位置"
        } else {
            bookmarkPromptDefault = "第 \(pdfCurrentPage) 页"
        }
        bookmarkDraftLabel = bookmarkPromptDefault
        showingBookmarkPrompt = true
    }

    func confirmAddBookmark() {
        guard let path = currentFilePath else {
            setStatus("需要文件路径才能保存书签")
            showingBookmarkPrompt = false
            return
        }
        if mode == .epub {
            guard let cfi = currentEpubCfi, !cfi.isEmpty else {
                setStatus("当前 EPUB 位置不可用")
                showingBookmarkPrompt = false
                return
            }
            let label = bookmarkDraftLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? bookmarkPromptDefault : bookmarkDraftLabel
            pendingBookmark = PendingBookmark(
                label: label,
                path: path,
                cfi: cfi,
                page: epubDisplayedPage,
                spineIndex: currentEpubSpineIndex
            )
            showingBookmarkPrompt = false
            epubBookmarkChapterPull = (UUID(), cfi)
            return
        }
        let label = bookmarkDraftLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? bookmarkPromptDefault : bookmarkDraftLabel
        let k = normalizePath(path)
        let row = ReaderBookmark(
            id: String(Int(Date().timeIntervalSince1970 * 1000)),
            label: label,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            page: pdfCurrentPage,
            cfi: nil,
            outlineTitle: PDFOutlineFlat.title(forPage: pdfCurrentPage, in: pdfOutline),
            epubSpineIndex: nil
        )
        if persistence.bookmarks[k] == nil { persistence.bookmarks[k] = [] }
        persistence.bookmarks[k]!.append(row)
        bookmarks = persistence.bookmarks[k] ?? []
        persist()
        showingBookmarkPrompt = false
        activeSidebar = .bookmarks
        setStatus("已添加书签: \(label)")
    }

    private func finalizePendingBookmark(outlineTitle: String?, spineIndex: Int?) {
        guard let pending = pendingBookmark else { return }
        pendingBookmark = nil
        let k = normalizePath(pending.path)
        let resolvedTitle = outlineTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSpine = spineIndex ?? pending.spineIndex
        let row = ReaderBookmark(
            id: String(Int(Date().timeIntervalSince1970 * 1000)),
            label: pending.label,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            page: pending.page,
            cfi: pending.cfi,
            outlineTitle: (resolvedTitle?.isEmpty == false) ? resolvedTitle : epubChapterTitle(forSpineIndex: resolvedSpine),
            epubSpineIndex: resolvedSpine
        )
        if persistence.bookmarks[k] == nil { persistence.bookmarks[k] = [] }
        persistence.bookmarks[k]!.append(row)
        bookmarks = persistence.bookmarks[k] ?? []
        persist()
        activeSidebar = .bookmarks
        setStatus("已添加书签: \(pending.label)")
    }

    func removeBookmark(id: String) {
        guard let path = currentFilePath else { return }
        let k = normalizePath(path)
        persistence.bookmarks[k]?.removeAll { $0.id == id }
        bookmarks = persistence.bookmarks[k] ?? []
        persist()
    }

    func jumpOutline(_ entry: PDFOutlineEntry) {
        goPdfPage(entry.page)
        activeSidebar = nil
    }

    func jumpEpubToc(href: String) {
        tocJumpToken = UUID()
        tocJumpHref = href
        activeSidebar = nil
    }

    func jumpBookmark(_ b: ReaderBookmark) {
        if let cfi = b.cfi {
            bookmarkJumpToken = UUID()
            bookmarkJumpCfi = cfi
            setStatus("已跳转到书签：\(b.label)")
        } else if let p = b.page {
            goPdfPage(p)
            setStatus("已跳转到第 \(p) 页")
        } else {
            setStatus("该书签缺少位置信息")
            return
        }
        activeSidebar = nil
    }

    func bookmarkPageLabel(_ b: ReaderBookmark) -> String? {
        b.page.map { "第 \($0) 页" }
    }

    func bookmarkOutlineLabel(_ b: ReaderBookmark) -> String? {
        if let title = b.outlineTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if mode == .pdf, let p = b.page {
            return PDFOutlineFlat.title(forPage: p, in: pdfOutline)
        }
        if mode == .epub, let idx = b.epubSpineIndex {
            return epubChapterTitle(forSpineIndex: idx)
        }
        return nil
    }

    func bookmarkCreatedLabel(_ b: ReaderBookmark) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: b.createdAt) else { return b.createdAt }
        let display = DateFormatter()
        display.dateStyle = .short
        display.timeStyle = .short
        return display.string(from: date)
    }

    func handleEpubBridgeMessage(_ msg: EpubWebReaderView.EpubBridgeMessage) {
        switch msg {
        case .location(let cfi, let page, let total, let spineIndex, _):
            if let cfi { saveEpubPosition(cfi: cfi) }
            epubDisplayedPage = page
            epubDisplayedTotal = total
            if let spineIndex { currentEpubSpineIndex = spineIndex }
        case .ready:
            epubTocPull = UUID()
        case .error(let s):
            setStatus("EPUB: \(s)")
        case .status(let s):
            if !s.isEmpty { setStatus(s) }
        default:
            break
        }
    }

    func applyEpubTocJSON(_ json: String) {
        struct Row: Codable { let title: String; let href: String; let spineIndex: Int? }
        guard let d = json.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Row].self, from: d) else {
            epubTocEntries = []
            return
        }
        epubTocEntries = rows.map { EpubTocEntry(title: $0.title, href: $0.href, spineIndex: $0.spineIndex ?? -1) }
    }

    func applyBookmarkChapterJSON(_ json: String) {
        struct Row: Codable { let title: String?; let spineIndex: Int? }
        let row = json.data(using: .utf8).flatMap { try? JSONDecoder().decode(Row.self, from: $0) }
        finalizePendingBookmark(outlineTitle: row?.title, spineIndex: row?.spineIndex)
    }

    func applyBookmarkBatchJSON(_ json: String) {
        struct Row: Codable { let cfi: String; let title: String?; let spineIndex: Int? }
        guard let path = currentFilePath,
              let d = json.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Row].self, from: d),
              !rows.isEmpty else { return }
        let k = normalizePath(path)
        var list = persistence.bookmarks[k] ?? []
        var changed = false
        for row in rows {
            guard let idx = list.firstIndex(where: { $0.cfi == row.cfi }) else { continue }
            var item = list[idx]
            var itemChanged = false
            if (item.outlineTitle == nil || item.outlineTitle!.isEmpty),
               let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                item.outlineTitle = title
                itemChanged = true
            }
            if item.epubSpineIndex == nil, let spine = row.spineIndex, spine >= 0 {
                item.epubSpineIndex = spine
                itemChanged = true
            }
            if itemChanged {
                list[idx] = item
                changed = true
            }
        }
        guard changed else { return }
        persistence.bookmarks[k] = list
        bookmarks = list
        persist()
    }

    func epubChapterTitle(forSpineIndex index: Int?) -> String? {
        guard let index, index >= 0, !epubTocEntries.isEmpty else { return nil }
        var bestIndex = -1
        var bestTitle: String?
        for entry in epubTocEntries {
            guard entry.spineIndex >= 0, entry.spineIndex <= index else { continue }
            if entry.spineIndex > bestIndex || entry.spineIndex == bestIndex {
                bestIndex = entry.spineIndex
                bestTitle = entry.title
            }
        }
        return bestTitle
    }

    func currentEpubChapterTitle() -> String? {
        epubChapterTitle(forSpineIndex: currentEpubSpineIndex)
    }

    private func resolveEpubBookmarkTitlesIfNeeded() {
        guard mode == .epub else { return }
        let cfis = bookmarks.compactMap { b -> String? in
            guard b.cfi != nil else { return nil }
            let hasTitle = b.outlineTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let needsSpine = b.epubSpineIndex == nil
            return (!hasTitle || needsSpine) ? b.cfi : nil
        }
        guard !cfis.isEmpty else { return }
        epubBookmarkBatchResolve = (UUID(), cfis)
    }
}
