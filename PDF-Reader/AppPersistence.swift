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
        do {
            return try decoder.decode(AppPersistenceData.self, from: data)
        } catch {
            return AppPersistenceData()
        }
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
