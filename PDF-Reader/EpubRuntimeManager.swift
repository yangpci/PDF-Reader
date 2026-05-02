//
//  EpubRuntimeManager.swift
//  PDF-Reader
//

import Foundation

enum EpubRuntimeManager {
    private static let folderName = "EpubRuntime"
    static let bookFilename = "current.epub"

    /// 与 WebKit 校验读权限时路径一致（解析符号链接，避免 `/Users` vs `/private/Users` 导致 no access）。
    static func canonicalFileDirectory(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func runtimeDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("pdf-reader-mac").appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return canonicalFileDirectory(dir)
    }

    static func bundleAssetURL(name: String, ext: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "EpubAssets") { return u }
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources/EpubAssets") { return u }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    static func syncBundledAssets() throws -> URL {
        let runtime = try runtimeDirectory()
        let fm = FileManager.default
        let pairs: [(String, String)] = [("epub-reader", "html"), ("epub-browser", "mjs")]
        for (name, ext) in pairs {
            guard let src = bundleAssetURL(name: name, ext: ext) else {
                throw NSError(domain: "EpubRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 \(name).\(ext)"])
            }
            let dst = runtime.appendingPathComponent("\(name).\(ext)")
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        return runtime
    }

    static func writeCurrentBook(data: Data, into runtime: URL) throws {
        let url = runtime.appendingPathComponent(bookFilename)
        try data.write(to: url, options: .atomic)
    }

    static func writeCurrentBook(data: Data) throws -> URL {
        let runtime = try runtimeDirectory()
        try writeCurrentBook(data: data, into: runtime)
        return runtime
    }

    static func htmlURL(inRuntime runtime: URL) -> URL {
        runtime.appendingPathComponent("epub-reader.html")
    }

    /// 供 `WKURLSchemeHandler` 加载入口页（与 html 内 `./epub-browser.mjs`、`fetch('./current.epub')` 同源）。
    static func epubReaderEntryURL() -> URL {
        URL(string: "\(EpubRuntimeSchemeHandler.scheme)://runtime/epub-reader.html")!
    }
}

extension String {
    var epubJSEscape: String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}
