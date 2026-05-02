//
//  PDF_ReaderApp.swift
//  PDF-Reader
//

import AppKit
import SwiftUI

@main
struct PDF_ReaderApp: App {
    @StateObject private var viewModel = ReaderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1160, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("文件") {
                Button("打开…") {
                    viewModel.chooseOpenFile()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("打开书架文件夹…") {
                    viewModel.chooseShelfFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("返回书架") {
                    viewModel.backToShelf()
                }
                .keyboardShortcut("b", modifiers: [.command])
            }
            CommandMenu("视图") {
                Button("放大") { viewModel.zoomIn() }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("缩小") { viewModel.zoomOut() }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("适应页面宽度") { viewModel.fitWidth() }
                    .keyboardShortcut("0", modifiers: [.command])
                Button("适应窗口高度") { viewModel.fitHeight() }
                    .keyboardShortcut("1", modifiers: [.command])
                Divider()
                Button("切换大纲 / 目录侧栏") { viewModel.toggleToc() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("设置…") { viewModel.showingSettings = true }
            }
            CommandMenu("书签") {
                Button("添加阅读书签…") { viewModel.beginAddBookmark() }
                    .keyboardShortcut("d", modifiers: [.command])
                Button("切换书签列表侧栏") { viewModel.toggleBookmarks() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
    }
}
