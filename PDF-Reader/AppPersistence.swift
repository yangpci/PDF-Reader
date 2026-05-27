//
//  AppPersistence.swift
//  PDF-Reader
//

import Foundation

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
    var readingPositions: [String: AnyCodableValue] = [:]
    var bookmarks: [String: [ReaderBookmark]] = [:]
    var shelfFolder: String?
    var shelfFolderHistory: [String] = []
    var shelfHistoryExcluded: [String] = []
    var theme: String = AppTheme.midnight.rawValue
    var pdfSpreadMode: String = "single"
}

enum AnyCodableValue: Codable, Hashable {
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) {
            self = .double(n)
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
        // 兼容被实验性字段污染的 JSON（如 pdfReadingSnapshots）
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AppPersistenceData()
        }
        root.removeValue(forKey: "pdfReadingSnapshots")
        guard let cleaned = try? JSONSerialization.data(withJSONObject: root),
              let recovered = try? decoder.decode(AppPersistenceData.self, from: cleaned) else {
            return AppPersistenceData()
        }
        return recovered
    }

    static func save(_ data: AppPersistenceData) {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(data).write(to: storageURL, options: .atomic)
        } catch {}
    }

    static func normalizePath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
