//
//  EpubWebReaderView.swift
//  PDF-Reader
//

import AppKit
import SwiftUI
import WebKit

struct EpubLoadSession {
    var id: UUID = UUID()
    var data: Data
    var startCfi: String?
}

struct EpubTocEntry: Hashable {
    let title: String
    let href: String
    let spineIndex: Int
}

struct EpubWebReaderView: NSViewRepresentable {
    var session: EpubLoadSession
    var theme: AppTheme
    var fontPercent: Int
    var tocJump: (token: UUID, href: String)?
    var bookmarkJump: (token: UUID, cfi: String)?
    var step: (token: UUID, delta: Int)?
    var tocPull: UUID?
    var bookmarkChapterPull: (token: UUID, cfi: String)?
    var bookmarkBatchResolve: (token: UUID, cfis: [String])?
    var onTocJSON: (String) -> Void
    var onBookmarkChapterJSON: (String) -> Void
    var onBookmarkBatchJSON: (String) -> Void
    var onMessage: (EpubBridgeMessage) -> Void

    enum EpubBridgeMessage: Equatable {
        case jsReady
        case ready
        case location(cfi: String?, page: Int?, total: Int?, spineIndex: Int?, href: String?)
        case error(String)
        case status(String)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onMessage: onMessage)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "epubBridge")
        config.setURLSchemeHandler(context.coordinator.epubSchemeHandler, forURLScheme: EpubRuntimeSchemeHandler.scheme)
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        if #available(macOS 11.0, *) {
            let w = WKWebpagePreferences()
            w.allowsContentJavaScript = true
            config.defaultWebpagePreferences = w
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = web
        context.coordinator.readerTheme = theme
        web.navigationDelegate = context.coordinator
        context.coordinator.reload(session: session, fontPercent: fontPercent)
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.onTocJSON = onTocJSON
        context.coordinator.onBookmarkChapterJSON = onBookmarkChapterJSON
        context.coordinator.onBookmarkBatchJSON = onBookmarkBatchJSON
        context.coordinator.readerTheme = theme
        context.coordinator.syncReaderChromeIfNeeded(webView: webView)
        if context.coordinator.lastSessionId != session.id {
            context.coordinator.reload(session: session, fontPercent: fontPercent)
        } else if context.coordinator.lastFont != fontPercent {
            context.coordinator.lastFont = fontPercent
            webView.evaluateJavaScript("setEpubFontPercent(\(fontPercent));", completionHandler: nil)
        }
        if let jump = tocJump, jump.token != context.coordinator.lastTocToken {
            context.coordinator.lastTocToken = jump.token
            webView.evaluateJavaScript("epubDisplayHref(\(jump.href.epubJSStringLiteral));", completionHandler: nil)
        }
        if let b = bookmarkJump, b.token != context.coordinator.lastBookmarkToken {
            context.coordinator.lastBookmarkToken = b.token
            webView.evaluateJavaScript("epubDisplayCFI(\(b.cfi.epubJSStringLiteral));", completionHandler: nil)
        }
        if let s = step, s.token != context.coordinator.lastStepToken {
            context.coordinator.lastStepToken = s.token
            let js = s.delta < 0 ? "epubPrev();" : "epubNext();"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        if let t = tocPull, t != context.coordinator.lastTocPull {
            context.coordinator.lastTocPull = t
            context.coordinator.pullToc(webView: webView)
        }
        if let pull = bookmarkChapterPull, pull.token != context.coordinator.lastBookmarkChapterToken {
            context.coordinator.lastBookmarkChapterToken = pull.token
            context.coordinator.pullBookmarkChapter(webView: webView, cfi: pull.cfi)
        }
        if let batch = bookmarkBatchResolve, batch.token != context.coordinator.lastBookmarkBatchToken {
            context.coordinator.lastBookmarkBatchToken = batch.token
            context.coordinator.resolveBookmarkBatch(webView: webView, cfis: batch.cfis)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onMessage: (EpubBridgeMessage) -> Void
        var onTocJSON: (String) -> Void = { _ in }
        var onBookmarkChapterJSON: (String) -> Void = { _ in }
        var onBookmarkBatchJSON: (String) -> Void = { _ in }
        var readerTheme: AppTheme = .midnight
        var lastAppliedReaderChromeHex: String?
        var lastSessionId: UUID?
        var lastFont: Int?
        var lastTocToken: UUID?
        var lastBookmarkToken: UUID?
        var lastTocPull: UUID?
        var lastBookmarkChapterToken: UUID?
        var lastBookmarkBatchToken: UUID?
        var lastStepToken: UUID?
        let epubSchemeHandler = EpubRuntimeSchemeHandler()
        private var pendingStartCfi: String?
        private var pendingFont: Int = 110
        /// `type="module"` 在 `didFinish` 之后才真正执行；须在收到 `jsReady` 后再调 `loadEpubFromFile`。
        private var epubPendingLoadApplied = false
        private var epubLoadFallbackWorkItem: DispatchWorkItem?

        init(onMessage: @escaping (EpubBridgeMessage) -> Void) {
            self.onMessage = onMessage
        }

        /// 推到下一轮 RunLoop，避免 WKWebView 回调落在 SwiftUI 更新周期内修改 `@Published`（控制台 “Publishing changes from within view updates”）。
        private func deliverBridge(_ msg: EpubBridgeMessage) {
            let handler = onMessage
            DispatchQueue.main.async {
                handler(msg)
            }
        }

        private func deliverTocJSON(_ json: String) {
            let handler = onTocJSON
            DispatchQueue.main.async {
                handler(json)
            }
        }

        private func deliverBookmarkChapterJSON(_ json: String) {
            let handler = onBookmarkChapterJSON
            DispatchQueue.main.async {
                handler(json)
            }
        }

        private func deliverBookmarkBatchJSON(_ json: String) {
            let handler = onBookmarkBatchJSON
            DispatchQueue.main.async {
                handler(json)
            }
        }

        func syncReaderChromeIfNeeded(webView: WKWebView) {
            let hex = readerTheme.pdfReaderChromeHex
            guard lastAppliedReaderChromeHex != hex else { return }
            lastAppliedReaderChromeHex = hex
            let js = "if (typeof setEpubChromeBackground === 'function') setEpubChromeBackground('\(hex)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func pullToc(webView: WKWebView) {
            if #available(macOS 11.0, *) {
                webView.callAsyncJavaScript("return await __epubNavTocJson();", arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let any):
                        if let s = any as? String {
                            self.deliverTocJSON(s)
                        }
                    case .failure:
                        break
                    }
                }
            }
        }

        func pullBookmarkChapter(webView: WKWebView, cfi: String) {
            if #available(macOS 11.0, *) {
                webView.callAsyncJavaScript(
                    "return await __epubChapterTitleForCfiJson(cfi);",
                    arguments: ["cfi": cfi],
                    in: nil,
                    in: .page
                ) { result in
                    switch result {
                    case .success(let any):
                        if let s = any as? String {
                            self.deliverBookmarkChapterJSON(s)
                        }
                    case .failure:
                        self.deliverBookmarkChapterJSON("{}")
                    }
                }
            }
        }

        func resolveBookmarkBatch(webView: WKWebView, cfis: [String]) {
            guard #available(macOS 11.0, *),
                  let data = try? JSONEncoder().encode(cfis),
                  let cfisJson = String(data: data, encoding: .utf8) else {
                deliverBookmarkBatchJSON("[]")
                return
            }
            webView.callAsyncJavaScript(
                "return await __epubResolveBookmarksJson(cfisJson);",
                arguments: ["cfisJson": cfisJson],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let any):
                    if let s = any as? String {
                        self.deliverBookmarkBatchJSON(s)
                    }
                case .failure:
                    self.deliverBookmarkBatchJSON("[]")
                }
            }
        }

        func reload(session: EpubLoadSession, fontPercent: Int) {
            guard let webView else { return }
            epubLoadFallbackWorkItem?.cancel()
            epubLoadFallbackWorkItem = nil
            epubPendingLoadApplied = false
            lastSessionId = session.id
            lastFont = fontPercent
            pendingStartCfi = session.startCfi
            pendingFont = fontPercent
            let data = session.data
            Task {
                do {
                    let runtime = try await Task.detached(priority: .userInitiated) {
                        let rt = try EpubRuntimeManager.syncBundledAssets()
                        try EpubRuntimeManager.writeCurrentBook(data: data, into: rt)
                        return rt
                    }.value
                    await MainActor.run {
                        self.epubSchemeHandler.runtimeFolderURL = runtime
                        webView.load(URLRequest(url: EpubRuntimeManager.epubReaderEntryURL()))
                    }
                } catch {
                    deliverBridge(.error(error.localizedDescription))
                }
            }
        }

        private func applyPendingEpubLoad(webView: WKWebView) {
            let startArg: String
            if let c = pendingStartCfi, !c.isEmpty {
                startArg = c.epubJSStringLiteral
            } else {
                startArg = "undefined"
            }
            let hex = readerTheme.pdfReaderChromeHex
            lastAppliedReaderChromeHex = hex
            let fname = EpubRuntimeManager.bookFilename.epubJSEscape
            let f = pendingFont

            let js = """
            (function(){
              try{
                var hex='\(hex)';
                var fname='\(fname)';
                var startCfi=\(startArg);
                var font=\(f);
                if(typeof setEpubChromeBackground==='function'){ setEpubChromeBackground(hex); }
                if(typeof loadEpubFromFile==='function' && typeof setEpubFontPercent==='function'){
                  loadEpubFromFile(fname,startCfi);
                  setEpubFontPercent(font);
                } else {
                  try{window.webkit.messageHandlers.epubBridge.postMessage({type:'error',message:'EPUB API 未就绪'});}catch(x){}
                }
              }catch(e){
                try{window.webkit.messageHandlers.epubBridge.postMessage({type:'error',message:(e&&e.message)?e.message:String(e)});}catch(x){}
              }
            })();
            """
            webView.evaluateJavaScript(js) { _, err in
                if let err {
                    self.deliverBridge(.error(err.localizedDescription))
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let u = webView.url, !u.lastPathComponent.isEmpty {
                let isEpubReader = u.lastPathComponent == "epub-reader.html"
                    || (u.scheme == EpubRuntimeSchemeHandler.scheme && u.host == "runtime" && u.lastPathComponent == "epub-reader.html")
                if !isEpubReader { return }
            }
            epubLoadFallbackWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard !self.epubPendingLoadApplied else { return }
                self.deliverBridge(.error("EPUB 模块加载超时，请检查 epub-browser.mjs 是否可读"))
            }
            epubLoadFallbackWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "epubBridge", let body = message.body as? [String: Any] else { return }
            guard let type = body["type"] as? String else { return }
            switch type {
            case "jsReady":
                if let w = webView, !epubPendingLoadApplied {
                    epubPendingLoadApplied = true
                    epubLoadFallbackWorkItem?.cancel()
                    epubLoadFallbackWorkItem = nil
                    applyPendingEpubLoad(webView: w)
                }
                deliverBridge(.jsReady)
            case "ready":
                deliverBridge(.ready)
            case "location":
                let cfi = body["cfi"] as? String
                let page = body["page"] as? Int
                let total = body["total"] as? Int
                let spineIndex = body["spineIndex"] as? Int
                let href = body["href"] as? String
                deliverBridge(.location(cfi: cfi, page: page, total: total, spineIndex: spineIndex, href: href))
            case "error":
                deliverBridge(.error((body["message"] as? String) ?? "未知错误"))
            case "status":
                deliverBridge(.status((body["text"] as? String) ?? ""))
            default:
                break
            }
        }
    }
}

private extension String {
    var epubJSStringLiteral: String {
        let e = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        return "'\(e)'"
    }
}
