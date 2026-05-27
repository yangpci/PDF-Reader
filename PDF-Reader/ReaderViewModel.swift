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
    @Published var pdfCurrentPage: Int = 1
    @Published var pdfTotalPages: Int = 0

    @Published var epubSession: EpubLoadSession?
    @Published var epubFontPercent: Int = 110
    @Published var epubDisplayedPage: Int?
    @Published var epubDisplayedTotal: Int?
    @Published var currentEpubCfi: String?

    @Published var zoomFieldText: String = "100%"

    @Published var statusText: String = "就绪"
    @Published var showingSettings = false
    @Published var showingToc = false
    @Published var showingBookmarks = false
    @Published var showingBookmarkPrompt = false
    @Published var bookmarkPromptDefault: String = ""
    @Published var bookmarkDraftLabel: String = ""

    @Published var bookmarks: [ReaderBookmark] = []
    @Published var tocJumpToken: UUID?
    @Published var tocJumpHref: String?
    @Published var bookmarkJumpToken: UUID?
    @Published var bookmarkJumpCfi: String?

    @Published var epubTocEntries: [(title: String, href: String)] = []
    @Published var epubTocPull: UUID?
    @Published var epubStepToken: UUID?
    @Published var epubStepDelta: Int = 0

    @Published var shelfHistory: [ShelfHistoryEntry] = []

    private var persistence: AppPersistenceData
    private var coverCache: [String: NSImage] = [:]
    private var savePositionTask: Task<Void, Never>?

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
        let saved = persistence.readingPositions[key]
        var start = 1
        if let v = saved {
            if let d = v.numberValue { start = max(1, Int(d)) }
        }
        pdfCurrentPage = min(max(1, start), max(1, doc.pageCount))
        bookmarks = persistence.bookmarks[key] ?? []
        if let outline = doc.outlineRoot {
            pdfOutline = PDFOutlineFlat.flatten(outline, document: doc)
        } else {
            pdfOutline = []
        }
        pdfScaleMode = .fitHeight
        setStatus("已打开 · 共 \(pdfTotalPages) 页")
        scheduleSavePdfPosition()
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
        showingToc.toggle()
        if showingToc, mode == .epub {
            epubTocPull = UUID()
        }
    }

    func toggleBookmarks() {
        showingBookmarks.toggle()
    }

    func goPdfPage(_ page: Int) {
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
        updateZoomField()
    }

    func fitWidth() {
        if mode == .epub {
            epubFontPercent = 110
            updateZoomField()
            return
        }
        pdfScaleMode = .fitWidth
    }

    func fitHeight() {
        if mode == .epub {
            epubFontPercent = 110
            updateZoomField()
            return
        }
        pdfScaleMode = .fitHeight
    }

    /// PDFView 实际缩放变化时同步工具栏百分比（双指缩放、适应宽/高等）。
    func syncPdfScaleFromReader(_ scale: CGFloat, userInitiated: Bool) {
        guard mode == .pdf else { return }
        let clamped = min(max(scale, 0.05), 10)
        let newText = "\(Int(round(clamped * 100)))%"

        if userInitiated, pdfScaleMode != .custom {
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
            updateZoomField()
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
        savePositionTask?.cancel()
        savePositionTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            persistence.readingPositions[key] = .double(Double(pdfCurrentPage))
            persist()
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
            bookmarkPromptDefault = "阅读位置"
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
        if mode == .epub && (currentEpubCfi == nil || currentEpubCfi!.isEmpty) {
            setStatus("当前 EPUB 位置不可用")
            showingBookmarkPrompt = false
            return
        }
        let label = bookmarkDraftLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? bookmarkPromptDefault : bookmarkDraftLabel
        let k = normalizePath(path)
        let row = ReaderBookmark(
            id: String(Int(Date().timeIntervalSince1970 * 1000)),
            label: label,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            page: mode == .pdf ? pdfCurrentPage : nil,
            cfi: mode == .epub ? currentEpubCfi : nil
        )
        if persistence.bookmarks[k] == nil { persistence.bookmarks[k] = [] }
        persistence.bookmarks[k]!.append(row)
        bookmarks = persistence.bookmarks[k] ?? []
        persist()
        showingBookmarkPrompt = false
        showingBookmarks = true
        setStatus("已添加书签: \(label)")
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
        showingToc = false
    }

    func jumpEpubToc(href: String) {
        tocJumpToken = UUID()
        tocJumpHref = href
        showingToc = false
    }

    func jumpBookmark(_ b: ReaderBookmark) {
        if let cfi = b.cfi {
            bookmarkJumpToken = UUID()
            bookmarkJumpCfi = cfi
        } else if let p = b.page {
            goPdfPage(p)
        }
        showingBookmarks = false
    }

    func handleEpubBridgeMessage(_ msg: EpubWebReaderView.EpubBridgeMessage) {
        switch msg {
        case .location(let cfi, let page, let total):
            if let cfi { saveEpubPosition(cfi: cfi) }
            epubDisplayedPage = page
            epubDisplayedTotal = total
        case .error(let s):
            setStatus("EPUB: \(s)")
        case .status(let s):
            if !s.isEmpty { setStatus(s) }
        default:
            break
        }
    }

    func applyEpubTocJSON(_ json: String) {
        struct Row: Codable { let title: String; let href: String }
        guard let d = json.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Row].self, from: d) else {
            epubTocEntries = []
            return
        }
        epubTocEntries = rows.map { ($0.title, $0.href) }
    }
}
