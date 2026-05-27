//
//  AppPersistence.swift
//  PDF-Reader
//

import Foundation

struct PdfReadingSnapshot: Codable, Hashable {
    var page: Int
    var anchorX: Double?
    var anchorY: Double?
    var scale: Double?
    var scaleMode: String?
    /// NSClipView.bounds.origin.x，与缩放配套时可直接恢复页内滚动（含水平位置）。
    var scrollOriginX: Double?
    /// NSClipView.bounds.origin.y
    var scrollOriginY: Double?
}

struct ReaderBookmark: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var createdAt: String
    var page: Int?
    var cfi: String?
    /// PDF 大纲 / EPUB 目录章节标题（旧数据可为 nil，展示时回填）
    var outlineTitle: String?
    /// EPUB 书脊索引，用于在无 outlineTitle 时匹配目录章节
    var epubSpineIndex: Int?
}

struct AppPersistenceData: Codable {
    var readingPositions: [String: AnyCodableValue]
    var pdfReadingSnapshots: [String: PdfReadingSnapshot]
    var bookmarks: [String: [ReaderBookmark]]
    var shelfFolder: String?
    var shelfFolderHistory: [String]
    var shelfHistoryExcluded: [String]
    var theme: String
    var pdfSpreadMode: String

    init(
        readingPositions: [String: AnyCodableValue] = [:],
        pdfReadingSnapshots: [String: PdfReadingSnapshot] = [:],
        bookmarks: [String: [ReaderBookmark]] = [:],
        shelfFolder: String? = nil,
        shelfFolderHistory: [String] = [],
        shelfHistoryExcluded: [String] = [],
        theme: String = AppTheme.midnight.rawValue,
        pdfSpreadMode: String = "single"
    ) {
        self.readingPositions = readingPositions
        self.pdfReadingSnapshots = pdfReadingSnapshots
        self.bookmarks = bookmarks
        self.shelfFolder = shelfFolder
        self.shelfFolderHistory = shelfFolderHistory
        self.shelfHistoryExcluded = shelfHistoryExcluded
        self.theme = theme
        self.pdfSpreadMode = pdfSpreadMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        readingPositions = try c.decodeIfPresent([String: AnyCodableValue].self, forKey: .readingPositions) ?? [:]
        pdfReadingSnapshots = try c.decodeIfPresent([String: PdfReadingSnapshot].self, forKey: .pdfReadingSnapshots) ?? [:]
        bookmarks = try c.decodeIfPresent([String: [ReaderBookmark]].self, forKey: .bookmarks) ?? [:]
        shelfFolder = try c.decodeIfPresent(String.self, forKey: .shelfFolder)
        shelfFolderHistory = try c.decodeIfPresent([String].self, forKey: .shelfFolderHistory) ?? []
        shelfHistoryExcluded = try c.decodeIfPresent([String].self, forKey: .shelfHistoryExcluded) ?? []
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? AppTheme.midnight.rawValue
        pdfSpreadMode = try c.decodeIfPresent(String.self, forKey: .pdfSpreadMode) ?? "single"
    }
}

enum AnyCodableValue: Codable, Hashable {
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) {
            self = .double(n)
        } else if let i = try? c.decode(Int.self) {
            self = .double(Double(i))
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported position value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .double(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }

    var numberValue: Double? {
        if case .double(let n) = self { return n }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

enum AppPersistence {
    private static let fileName = "pdf-reader-data.json"
    private static let supportSubdir = "pdf-reader-mac"

    static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(supportSubdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> AppPersistenceData {
        let url = storageURL
        guard let data = try? Data(contentsOf: url) else { return AppPersistenceData() }
        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode(AppPersistenceData.self, from: data) {
            return loaded
        }
        return salvage(from: data)
    }

    static func save(_ data: AppPersistenceData) {
        var outgoing = data
        if let diskData = try? Data(contentsOf: storageURL),
           let disk = try? JSONDecoder().decode(AppPersistenceData.self, from: diskData) {
            outgoing = merge(preserved: disk, updates: outgoing)
        }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(outgoing).write(to: storageURL, options: .atomic)
        } catch {}
    }

    /// 解码失败时尽量从原始 JSON 挽回书架、主题等关键字段，避免返回空数据后被 persist 覆盖。
    private static func salvage(from data: Data) -> AppPersistenceData {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AppPersistenceData()
        }
        var cleaned = root
        if let snapshots = cleaned["pdfReadingSnapshots"], JSONSerialization.isValidJSONObject(snapshots),
           let snapData = try? JSONSerialization.data(withJSONObject: snapshots),
           (try? JSONDecoder().decode([String: PdfReadingSnapshot].self, from: snapData)) == nil {
            cleaned.removeValue(forKey: "pdfReadingSnapshots")
        }
        guard let normalized = try? JSONSerialization.data(withJSONObject: cleaned),
              let recovered = try? JSONDecoder().decode(AppPersistenceData.self, from: normalized) else {
            return manualSalvage(from: root)
        }
        return recovered
    }

    private static func manualSalvage(from root: [String: Any]) -> AppPersistenceData {
        AppPersistenceData(
            readingPositions: [:],
            pdfReadingSnapshots: [:],
            bookmarks: [:],
            shelfFolder: root["shelfFolder"] as? String,
            shelfFolderHistory: root["shelfFolderHistory"] as? [String] ?? [],
            shelfHistoryExcluded: root["shelfHistoryExcluded"] as? [String] ?? [],
            theme: root["theme"] as? String ?? AppTheme.midnight.rawValue,
            pdfSpreadMode: root["pdfSpreadMode"] as? String ?? "single"
        )
    }

    /// 若内存中关键配置已丢失，保留磁盘上已有值，防止局部更新 wipe 全文件。
    private static func merge(preserved disk: AppPersistenceData, updates memory: AppPersistenceData) -> AppPersistenceData {
        var out = memory
        if out.shelfFolder == nil { out.shelfFolder = disk.shelfFolder }
        if out.shelfFolderHistory.isEmpty, !disk.shelfFolderHistory.isEmpty {
            out.shelfFolderHistory = disk.shelfFolderHistory
        }
        if out.shelfHistoryExcluded.isEmpty, !disk.shelfHistoryExcluded.isEmpty {
            out.shelfHistoryExcluded = disk.shelfHistoryExcluded
        }
        if out.theme == AppTheme.midnight.rawValue, disk.theme != AppTheme.midnight.rawValue {
            out.theme = disk.theme
        }
        for (key, value) in disk.bookmarks where out.bookmarks[key] == nil {
            out.bookmarks[key] = value
        }
        for (key, value) in disk.readingPositions where out.readingPositions[key] == nil {
            out.readingPositions[key] = value
        }
        for (key, value) in disk.pdfReadingSnapshots where out.pdfReadingSnapshots[key] == nil {
            out.pdfReadingSnapshots[key] = value
        }
        if out.pdfSpreadMode == "single", disk.pdfSpreadMode != "single" {
            out.pdfSpreadMode = disk.pdfSpreadMode
        }
        return out
    }

    static func normalizePath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
