//
//  ContentView.swift
//  PDF-Reader
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var vm: ReaderViewModel
    @State private var shelfHistoryPopoverOpen = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack(alignment: .trailing) {
                Group {
                    switch vm.mode {
                    case .welcome:
                        welcomeDrop
                    case .shelf:
                        shelfGrid
                    case .pdf:
                        pdfArea
                    case .epub:
                        epubArea
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if vm.showingToc {
                    tocSidebar
                }
                if vm.showingBookmarks {
                    bookmarkSidebar
                }
            }
            statusBar
        }
        .background(vm.uiTheme.primaryBg)
        .tint(vm.uiTheme.accent)
        .sheet(isPresented: $vm.showingSettings) {
            settingsSheet
        }
        .alert("添加书签", isPresented: $vm.showingBookmarkPrompt) {
            TextField("名称", text: $vm.bookmarkDraftLabel)
            Button("取消", role: .cancel) { vm.showingBookmarkPrompt = false }
            Button("确定") { vm.confirmAddBookmark() }
        } message: {
            Text("为当前阅读位置保存书签")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if vm.mode != .pdf && vm.mode != .epub {
                Button(action: { vm.chooseOpenFile() }) {
                    Label("打开", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    shelfHistoryPopoverOpen = true
                } label: {
                    Label("书架", systemImage: "books.vertical")
                }
                .buttonStyle(.bordered)
                .help("查看与管理历史书架文件夹")
                .popover(isPresented: $shelfHistoryPopoverOpen, arrowEdge: .bottom) {
                    shelfHistoryPopoverPanel
                }
            }

            if vm.mode == .pdf || vm.mode == .epub {
                Button(action: { vm.backToShelf() }) {
                    Label("返回书架", systemImage: "arrow.backward")
                }
                .keyboardShortcut("b", modifiers: [.command])

                Divider().frame(height: 18)

                Button(action: { vm.stepReading(delta: -1) }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(vm.mode == .pdf && vm.pdfCurrentPage <= 1)
                .keyboardShortcut(.leftArrow, modifiers: [])

                HStack(spacing: 6) {
                    if vm.mode == .pdf {
                        TextField("", value: $vm.pdfCurrentPage, format: .number)
                            .frame(width: 44)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .onSubmit {
                                vm.goPdfPage(vm.pdfCurrentPage)
                            }
                    } else {
                        Text(vm.epubDisplayedPage.map(String.init) ?? "—")
                            .foregroundStyle(vm.uiTheme.dimText)
                            .frame(minWidth: 24)
                    }
                    Text("/")
                        .foregroundStyle(vm.uiTheme.dimText)
                    Text(vm.mode == .pdf ? "\(vm.pdfTotalPages)" : (vm.epubDisplayedTotal.map(String.init) ?? "—"))
                        .foregroundStyle(vm.uiTheme.dimText)
                }

                Button(action: { vm.stepReading(delta: 1) }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(vm.mode == .pdf && vm.pdfCurrentPage >= vm.pdfTotalPages)
                .keyboardShortcut(.rightArrow, modifiers: [])

                Divider().frame(height: 18)

                Button(action: { vm.zoomOut() }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: [.command])

                TextField("", text: $vm.zoomFieldText)
                    .frame(width: 56)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .onSubmit { vm.applyZoomFieldEditingEnded() }
                    .onChange(of: vm.zoomFieldText) { _, _ in }

                Button(action: { vm.zoomIn() }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button(action: { vm.fitWidth() }) {
                    Image(systemName: "arrow.left.and.right.square")
                }
                .help("适应宽度")
                .keyboardShortcut("0", modifiers: [.command])

                Button(action: { vm.fitHeight() }) {
                    Image(systemName: "arrow.up.and.down.square")
                }
                .help("适应高度")
                .keyboardShortcut("1", modifiers: [.command])

                Divider().frame(height: 18)

                Button(action: { vm.toggleToc() }) {
                    Label("目录", systemImage: "list.bullet")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button(action: { vm.beginAddBookmark() }) {
                    Image(systemName: "bookmark")
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button(action: { vm.toggleBookmarks() }) {
                    Label("书签", systemImage: "bookmark.square")
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }

            Spacer(minLength: 8)

            Button(action: { vm.showingSettings = true }) {
                Image(systemName: "gearshape")
            }
            .help("设置")
        }
        .padding(10)
        .background(vm.uiTheme.secondaryBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(vm.uiTheme.border).frame(height: 1)
        }
    }

    private var shelfHistoryPopoverPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.shelfHistory.isEmpty {
                shelfHistoryEmptyState
            } else {
                shelfHistoryPopoverHeader(count: vm.shelfHistory.count)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.shelfHistory, id: \.path) { h in
                            shelfHistoryRow(h)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .frame(minWidth: 400, idealWidth: 460, minHeight: 120, maxHeight: 340)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(vm.uiTheme.primaryBg)
    }

    private var shelfHistoryEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 32))
                .foregroundStyle(vm.uiTheme.accent.opacity(0.9))
                .padding(18)
                .background(
                    Circle()
                        .fill(vm.uiTheme.accent.opacity(0.12))
                )
            Text("暂无书架历史")
                .font(.headline)
                .foregroundStyle(vm.uiTheme.text)
            Text("在菜单栏选择「文件 → 打开书架文件夹…」添加后，会在此列出最近使用过的路径。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(vm.uiTheme.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(minWidth: 320)
    }

    private func shelfHistoryPopoverHeader(count: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(vm.uiTheme.accent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("历史书架")
                    .font(.headline)
                    .foregroundStyle(vm.uiTheme.text)
                Text("左键打开 · 右键移除记录")
                    .font(.caption2)
                    .foregroundStyle(vm.uiTheme.dimText)
            }
            Spacer(minLength: 8)
            Text("\(count) 条")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(vm.uiTheme.text)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(vm.uiTheme.secondaryBg.opacity(0.9))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(vm.uiTheme.border.opacity(0.5), lineWidth: 1)
                )
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(vm.uiTheme.secondaryBg.opacity(0.4))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(vm.uiTheme.border.opacity(0.35))
                .frame(height: 1)
        }
    }

    private func shelfHistoryRow(_ h: ShelfHistoryEntry) -> some View {
        let expanded = (h.path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let folderName = url.lastPathComponent
        let parentDisplay = url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        return Button {
            guard h.exists else { return }
            vm.switchShelfHistory(path: h.path)
            shelfHistoryPopoverOpen = false
        } label: {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(vm.uiTheme.accent.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: h.exists ? "folder.fill" : "folder.badge.questionmark")
                        .font(.title3)
                        .foregroundStyle(h.exists ? vm.uiTheme.accent : vm.uiTheme.dimText)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(folderName.isEmpty ? expanded : folderName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(h.exists ? vm.uiTheme.text : vm.uiTheme.dimText)
                        .lineLimit(1)
                    Text(parentDisplay)
                        .font(.caption)
                        .foregroundStyle(vm.uiTheme.dimText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !h.exists {
                    Text("路径失效")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.14))
                        )
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(vm.uiTheme.dimText.opacity(0.65))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(vm.uiTheme.pdfBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(vm.uiTheme.border.opacity(0.45), lineWidth: 1)
            )
            .opacity(h.exists ? 1 : 0.72)
        }
        .buttonStyle(.plain)
        .help(expanded)
        .contextMenu {
            Button("从历史移除", role: .destructive) {
                vm.removeShelfHistory(path: h.path)
            }
        }
    }

    private var welcomeDrop: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 56))
                .foregroundStyle(vm.uiTheme.dimText)
            Text("将 PDF 或 EPUB 拖放到窗口")
                .font(.title3)
                .foregroundStyle(vm.uiTheme.text)
            Text("或使用左上角「打开」「书架」")
                .foregroundStyle(vm.uiTheme.dimText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(vm.uiTheme.primaryBg)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private var shelfGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(vm.shelfTitle)
                    .font(.title2.bold())
                    .foregroundStyle(vm.uiTheme.text)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(vm.shelfEntries) { entry in
                        Button {
                            vm.openShelfEntry(entry)
                        } label: {
                            VStack(spacing: 8) {
                                Group {
                                    if let img = vm.shelfCover(path: entry.url.path) {
                                        Image(nsImage: img)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 100, height: 140)
                                            .background(vm.uiTheme.pdfBg)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    } else {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(vm.uiTheme.pdfBg)
                                            .frame(width: 100, height: 140)
                                            .overlay {
                                                Image(systemName: entry.url.pathExtension.lowercased() == "epub" ? "book" : "doc.richtext")
                                                    .font(.largeTitle)
                                                    .foregroundStyle(vm.uiTheme.dimText)
                                            }
                                    }
                                }
                                Text(entry.name)
                                    .font(.caption)
                                    .foregroundStyle(vm.uiTheme.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 120)
                                if entry.url.pathExtension.lowercased() == "pdf",
                                   let pct = vm.readingPercentForShelfPdf(path: entry.url.path) {
                                    Text("已读 \(pct)%")
                                        .font(.caption2)
                                        .foregroundStyle(vm.uiTheme.dimText)
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(vm.uiTheme.border.opacity(0.6))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                if vm.shelfEntries.isEmpty {
                    Text("此文件夹暂无 PDF / EPUB")
                        .foregroundStyle(vm.uiTheme.dimText)
                }
            }
            .padding(20)
        }
        .background(vm.uiTheme.primaryBg)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private var pdfArea: some View {
        Group {
            PDFKitReaderView(
                document: Binding(
                    get: { vm.pdfDocument },
                    set: { vm.pdfDocument = $0 }
                ),
                theme: vm.uiTheme,
                spreadMode: vm.pdfDisplayMode(),
                scaleMode: vm.pdfScaleMode,
                customScale: vm.pdfCustomScale,
                currentPage: vm.pdfCurrentPage,
                onPageChange: { p in
                    vm.pdfCurrentPage = p
                    vm.scheduleSavePdfPosition()
                },
                onDocumentLoaded: { total in
                    vm.pdfTotalPages = total
                }
            )
            .background(vm.uiTheme.pdfBg)
            .onChange(of: vm.pdfScaleMode) { _, _ in vm.updateZoomField() }
            .onChange(of: vm.pdfCustomScale) { _, _ in vm.updateZoomField() }
            .onChange(of: vm.pdfCurrentPage) { _, _ in vm.updateZoomField() }
        }
    }

    private var epubArea: some View {
        Group {
            if let session = vm.epubSession {
                EpubWebReaderView(
                    session: session,
                    theme: vm.uiTheme,
                    fontPercent: vm.epubFontPercent,
                    tocJump: vm.tocJumpToken.flatMap { t in vm.tocJumpHref.map { (token: t, href: $0) } },
                    bookmarkJump: vm.bookmarkJumpToken.flatMap { t in vm.bookmarkJumpCfi.map { (token: t, cfi: $0) } },
                    step: vm.epubStepToken.map { (token: $0, delta: vm.epubStepDelta) },
                    tocPull: vm.epubTocPull,
                    onTocJSON: { vm.applyEpubTocJSON($0) },
                    onMessage: { vm.handleEpubBridgeMessage($0) }
                )
                .background(vm.uiTheme.pdfBg)
            } else {
                Text("EPUB 未加载").foregroundStyle(vm.uiTheme.dimText)
            }
        }
    }

    private var tocSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(vm.mode == .epub ? "EPUB 目录" : "PDF 大纲目录")
                    .font(.headline)
                    .foregroundStyle(vm.uiTheme.text)
                Spacer()
                Button("关闭") { vm.showingToc = false }
            }
            .padding(12)
            .background(vm.uiTheme.secondaryBg)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if vm.mode == .pdf {
                        ForEach(vm.pdfOutline) { row in
                            Button {
                                vm.jumpOutline(row)
                            } label: {
                                HStack {
                                    Text(row.title).foregroundStyle(vm.uiTheme.text)
                                    Spacer()
                                    Text("\(row.page)").foregroundStyle(vm.uiTheme.dimText).font(.caption.monospacedDigit())
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(vm.uiTheme.primaryBg))
                            }
                            .buttonStyle(.plain)
                        }
                        if vm.pdfOutline.isEmpty {
                            Text("该 PDF 未提供大纲结构")
                                .foregroundStyle(vm.uiTheme.dimText)
                                .padding(.top, 8)
                        }
                    } else {
                        ForEach(Array(vm.epubTocEntries.enumerated()), id: \.offset) { _, pair in
                            Button(pair.0) {
                                vm.jumpEpubToc(href: pair.1)
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(vm.uiTheme.primaryBg))
                            .foregroundStyle(vm.uiTheme.text)
                        }
                        if vm.epubTocEntries.isEmpty {
                            Text("正在加载目录或本书无导航…")
                                .foregroundStyle(vm.uiTheme.dimText)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 300)
        .background(vm.uiTheme.secondaryBg)
        .overlay(alignment: .leading) {
            Rectangle().fill(vm.uiTheme.border).frame(width: 1)
        }
    }

    private var bookmarkSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("我的书签")
                    .font(.headline)
                    .foregroundStyle(vm.uiTheme.text)
                Spacer()
                Button("关闭") { vm.showingBookmarks = false }
            }
            .padding(12)
            .background(vm.uiTheme.secondaryBg)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if vm.bookmarks.isEmpty {
                        Text("尚无书签\n可使用 ⌘D 添加")
                            .foregroundStyle(vm.uiTheme.dimText)
                            .multilineTextAlignment(.center)
                            .padding(.top, 24)
                    } else {
                        ForEach(vm.bookmarks) { b in
                            VStack(alignment: .leading, spacing: 4) {
                                Button(b.label) {
                                    vm.jumpBookmark(b)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(vm.uiTheme.text)
                                Text(b.createdAt)
                                    .font(.caption2)
                                    .foregroundStyle(vm.uiTheme.dimText)
                                Button("删除", role: .destructive) {
                                    vm.removeBookmark(id: b.id)
                                }
                                .font(.caption)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(vm.uiTheme.primaryBg))
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 280)
        .background(vm.uiTheme.secondaryBg)
        .overlay(alignment: .leading) {
            Rectangle().fill(vm.uiTheme.border).frame(width: 1)
        }
    }

    private var statusBar: some View {
        HStack {
            if !vm.currentFileName.isEmpty && (vm.mode == .pdf || vm.mode == .epub) {
                Text(vm.currentFileName)
                    .lineLimit(1)
                    .foregroundStyle(vm.uiTheme.dimText)
            }
            Spacer()
            if vm.mode == .pdf {
                Text("第 \(vm.pdfCurrentPage) / \(max(vm.pdfTotalPages, 1)) 页")
                    .foregroundStyle(vm.uiTheme.dimText)
            } else if vm.mode == .epub {
                if let p = vm.epubDisplayedPage, let t = vm.epubDisplayedTotal {
                    Text("EPUB · 第 \(p) / \(t) 页")
                        .foregroundStyle(vm.uiTheme.dimText)
                }
            }
            if vm.isBookmarkedHere {
                Label("已添加书签", systemImage: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(vm.uiTheme.bookmarkGold)
            }
            Text(vm.statusText)
                .foregroundStyle(vm.uiTheme.dimText.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(vm.uiTheme.secondaryBg)
        .overlay(alignment: .top) {
            Rectangle().fill(vm.uiTheme.border).frame(height: 1)
        }
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置")
                .font(.title2)
            Text("主题")
                .font(.headline)
            Picker("主题", selection: Binding(
                get: { vm.uiTheme },
                set: { vm.applyTheme($0) }
            )) {
                ForEach(AppTheme.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.radioGroup)

            Text("PDF 页面")
                .font(.headline)
            Toggle("双页并排", isOn: Binding(
                get: { vm.pdfSpreadDouble },
                set: { vm.applyPdfSpread(double: $0) }
            ))

            Spacer()
            HStack {
                Spacer()
                Button("关闭") { vm.showingSettings = false }
            }
        }
        .padding(22)
        .frame(minWidth: 400, minHeight: 360)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let ext = url.pathExtension.lowercased()
                guard ext == "pdf" || ext == "epub" else { return }
                DispatchQueue.main.async {
                    vm.openChosenFile(url: url)
                }
            }
            return true
        }
        return false
    }
}
