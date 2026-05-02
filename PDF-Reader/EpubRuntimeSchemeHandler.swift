//
//  EpubRuntimeSchemeHandler.swift
//  PDF-Reader
//
//  使用自定义 scheme 提供 EPUB 运行时文件，避免 WebContent 对 file:// 的 hasAssumedReadAccessToURL 限制。
//

import Foundation
import WebKit

final class EpubRuntimeSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pdfreader-epub"

    /// 包含 epub-reader.html、epub-browser.mjs、current.epub 的目录（建议使用规范化后的路径）。
    var runtimeFolderURL: URL?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let folder = runtimeFolderURL else {
            urlSchemeTask.didFailWithError(NSError(domain: "EpubScheme", code: 1, userInfo: [NSLocalizedDescriptionKey: "EPUB runtime 未配置"]))
            return
        }
        guard let reqURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "EpubScheme", code: 2, userInfo: [NSLocalizedDescriptionKey: "无效请求"]))
            return
        }
        let name = reqURL.lastPathComponent
        let allowed: Set<String> = ["epub-reader.html", "epub-browser.mjs", EpubRuntimeManager.bookFilename]
        guard allowed.contains(name) else {
            urlSchemeTask.didFailWithError(NSError(domain: "EpubScheme", code: 3, userInfo: [NSLocalizedDescriptionKey: "禁止访问 \(name)"]))
            return
        }
        let fileURL = folder.appendingPathComponent(name)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: fileURL)
                let mime: String
                if name.hasSuffix(".html") {
                    mime = "text/html; charset=utf-8"
                } else if name.hasSuffix(".mjs") {
                    mime = "application/javascript; charset=utf-8"
                } else if name.hasSuffix(".epub") {
                    mime = "application/epub+zip"
                } else {
                    mime = "application/octet-stream"
                }
                guard let response = HTTPURLResponse(
                    url: reqURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": mime]
                ) else {
                    throw NSError(domain: "EpubScheme", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法构造响应"])
                }
                DispatchQueue.main.async {
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
            } catch {
                DispatchQueue.main.async {
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
