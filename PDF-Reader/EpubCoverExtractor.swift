//
//  EpubCoverExtractor.swift
//  PDF-Reader
//

import AppKit
import Foundation

enum EpubCoverExtractor {
    private static func unzipData(epub: URL, innerPath: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", epub.path, innerPath]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func parseContainerOPFPath(containerXML: String) -> String? {
        guard let r = containerXML.range(of: "full-path=\"") else { return nil }
        let start = r.upperBound
        guard let end = containerXML[start...].firstIndex(of: "\"") else { return nil }
        return String(containerXML[start..<end])
    }

    private static func firstMatchGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges >= 2,
              let gr = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[gr])
    }

    private static func parseCoverImagePath(opfXML: String, opfDir: String) -> String? {
        var coverId: String?
        if let id = firstMatchGroup(#"<meta[^>]+name="cover"[^>]+content="([^"]+)""#, in: opfXML) {
            coverId = id
        } else if let id = firstMatchGroup(#"<meta[^>]+content="([^"]+)"[^>]+name="cover""#, in: opfXML) {
            coverId = id
        }

        var hrefById: [String: String] = [:]
        let itemPattern = #"<item\b([^>]+)/>"#
        if let re = try? NSRegularExpression(pattern: itemPattern, options: []) {
            let ns = opfXML as NSString
            let full = NSRange(location: 0, length: ns.length)
            re.enumerateMatches(in: opfXML, options: [], range: full) { result, _, _ in
                guard let r = result, r.range.length > 0 else { return }
                let frag = ns.substring(with: r.range(at: 1))
                if let iid = firstMatchGroup(#"id="([^"]+)""#, in: frag),
                   let href = firstMatchGroup(#"href="([^"]+)""#, in: frag) {
                    hrefById[iid] = href
                }
            }
        }

        if let cid = coverId, let href = hrefById[cid] {
            return joinOPF(dir: opfDir, href: href)
        }

        for (_, href) in hrefById where href.lowercased().contains("cover") && (href.hasSuffix(".jpg") || href.hasSuffix(".jpeg") || href.hasSuffix(".png")) {
            return joinOPF(dir: opfDir, href: href)
        }

        return nil
    }

    private static func joinOPF(dir: String, href: String) -> String {
        if href.hasPrefix("/") { return String(href.dropFirst()) }
        if dir.isEmpty { return href }
        let clean = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return "\(clean)/\(href)"
    }

    static func coverImage(epubURL: URL) -> NSImage? {
        guard let cData = unzipData(epub: epubURL, innerPath: "META-INF/container.xml"),
              let cStr = String(data: cData, encoding: .utf8),
              let opfRel = parseContainerOPFPath(containerXML: cStr) else { return nil }
        guard let opfData = unzipData(epub: epubURL, innerPath: opfRel),
              let opfStr = String(data: opfData, encoding: .utf8) else { return nil }
        let opfDir = (opfRel as NSString).deletingLastPathComponent
        guard let imgRel = parseCoverImagePath(opfXML: opfStr, opfDir: opfDir) else { return nil }
        guard let imgData = unzipData(epub: epubURL, innerPath: imgRel) else { return nil }
        return NSImage(data: imgData)
    }
}
