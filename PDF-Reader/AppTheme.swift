//
//  AppTheme.swift
//  PDF-Reader
//

import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case midnight
    case graphite
    case ocean
    case amber
    case paper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .midnight: return "午夜蓝"
        case .graphite: return "石墨灰"
        case .ocean: return "深海青"
        case .amber: return "琥珀棕"
        case .paper: return "日间纸本"
        }
    }

    var windowBackground: Color {
        switch self {
        case .midnight: return Color(red: 0.1, green: 0.1, blue: 0.18)
        case .graphite: return Color(red: 0.09, green: 0.09, blue: 0.11)
        case .ocean: return Color(red: 0.04, green: 0.07, blue: 0.13)
        case .amber: return Color(red: 0.13, green: 0.11, blue: 0.08)
        case .paper: return Color(red: 0.93, green: 0.94, blue: 0.96)
        }
    }

    var primaryBg: Color {
        switch self {
        case .midnight: return Color(red: 0.1, green: 0.1, blue: 0.18)
        case .graphite: return Color(red: 0.08, green: 0.08, blue: 0.09)
        case .ocean: return Color(red: 0.04, green: 0.07, blue: 0.13)
        case .amber: return Color(red: 0.13, green: 0.11, blue: 0.08)
        case .paper: return Color(red: 0.93, green: 0.94, blue: 0.96)
        }
    }

    var secondaryBg: Color {
        switch self {
        case .midnight: return Color(red: 0.09, green: 0.13, blue: 0.24)
        case .graphite: return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .ocean: return Color(red: 0.07, green: 0.11, blue: 0.18)
        case .amber: return Color(red: 0.18, green: 0.15, blue: 0.09)
        case .paper: return Color.white
        }
    }

    var accent: Color {
        switch self {
        case .midnight: return Color(red: 0.06, green: 0.2, blue: 0.38)
        case .graphite: return Color(red: 0.24, green: 0.26, blue: 0.33)
        case .ocean: return Color(red: 0.1, green: 0.29, blue: 0.48)
        case .amber: return Color(red: 0.36, green: 0.29, blue: 0.17)
        case .paper: return Color(red: 0.15, green: 0.39, blue: 0.92)
        }
    }

    var text: Color {
        switch self {
        case .paper: return Color(red: 0.1, green: 0.11, blue: 0.14)
        default: return Color(red: 0.91, green: 0.91, blue: 0.91)
        }
    }

    var dimText: Color {
        switch self {
        case .paper: return Color(red: 0.36, green: 0.39, blue: 0.44)
        default: return Color(red: 0.63, green: 0.63, blue: 0.63)
        }
    }

    var border: Color {
        switch self {
        case .paper: return Color(red: 0.82, green: 0.84, blue: 0.87)
        default: return Color(red: 0.2, green: 0.2, blue: 0.33)
        }
    }

    /// PDF / EPUB 阅读画布周围衬色（与 `primaryBg` 区分，略提亮以便衬托纸面）。
    var pdfBg: Color {
        let t = Self.readerCanvasRGB(self)
        return Color(red: Double(t.0), green: Double(t.1), blue: Double(t.2))
    }

    /// `PDFView` 背景，与 `pdfBg` 同源（勿在视图里写死颜色）。
    var pdfReaderChromeNSColor: NSColor {
        let t = Self.readerCanvasRGB(self)
        return NSColor(calibratedRed: t.0, green: t.1, blue: t.2, alpha: 1)
    }

    /// 供 EPUB WebView 设置的 `#RRGGBB`，与 `pdfBg` 同源。
    var pdfReaderChromeHex: String {
        let t = Self.readerCanvasRGB(self)
        return String(
            format: "#%02X%02X%02X",
            Int(round(t.0 * 255)),
            Int(round(t.1 * 255)),
            Int(round(t.2 * 255))
        )
    }

    var bookmarkGold: Color {
        switch self {
        case .paper: return Color(red: 0.71, green: 0.33, blue: 0.04)
        case .ocean: return Color(red: 0.37, green: 0.92, blue: 0.83)
        default: return Color(red: 0.95, green: 0.61, blue: 0.07)
        }
    }

    static func fromStorage(_ raw: String) -> AppTheme {
        AppTheme(rawValue: raw) ?? .midnight
    }

    /// 阅读区画布衬色 RGB（calibrated 0…1），单一数据源。
    private static func readerCanvasRGB(_ theme: AppTheme) -> (CGFloat, CGFloat, CGFloat) {
        switch theme {
        case .midnight: return (0.16, 0.16, 0.24)
        case .graphite: return (0.13, 0.14, 0.17)
        case .ocean: return (0.06, 0.1, 0.18)
        case .amber: return (0.18, 0.16, 0.11)
        case .paper: return (0.89, 0.9, 0.93)
        }
    }
}
