import Foundation
import PDFKit
import UIKit

// MARK: - 打印内容来源

enum PrintSource: Equatable {
    case test
    case file(URL)
    case web(String)

    var title: String {
        switch self {
        case .test: return "测试页"
        case .file(let url): return url.lastPathComponent
        case .web(let raw): return raw
        }
    }

    var kindLabel: String {
        switch self {
        case .test: return "内置测试页"
        case .file(let url):
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" { return "PDF 文档" }
            if ["png", "jpg", "jpeg", "heic", "gif", "bmp", "tiff", "webp"].contains(ext) {
                return "图片"
            }
            if ["html", "htm"].contains(ext) { return "网页文件" }
            return "文本文件"
        case .web: return "网页"
        }
    }
}

enum PrintSourceError: LocalizedError {
    case unsupported(String)
    case emptyFile
    case badPDF
    case badImage
    case badText
    case emptyText
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext):
            return "不支持的文件类型（.\(ext)）"
        case .emptyFile:
            return "文件是空的"
        case .badPDF:
            return "PDF 无法读取或已损坏"
        case .badImage:
            return "图片无法读取"
        case .badText:
            return "文本编码无法识别"
        case .emptyText:
            return "文本内容为空"
        case .encodingFailed:
            return "打印数据生成失败（图片编码失败）"
        }
    }
}

// MARK: - 测试页 / 文本

enum PrintContent {

    /// 测试页：标题 + 打印机信息 + 对齐测试。
    static func testPage(
        printer: PrinterConfig,
        options: PrintOptions,
        format: PrintFormat,
        dpi: CGFloat
    ) -> NSAttributedString {
        let compact = format.isReceipt
        let body = compact ? TextLayout.font(dpi: dpi, pointSize: 9) : TextLayout.font(dpi: dpi, pointSize: 12)
        let title = compact
            ? TextLayout.font(dpi: dpi, pointSize: 15, weight: .bold)
            : TextLayout.font(dpi: dpi, pointSize: 21, weight: .bold)
        let subtitle = compact
            ? TextLayout.font(dpi: dpi, pointSize: 11, weight: .semibold)
            : TextLayout.font(dpi: dpi, pointSize: 14, weight: .semibold)

        let now = DateFormatter()
        now.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let paperText = format.isReceipt
            ? (format == .esc80 ? "80mm 热敏小票纸" : "58mm 热敏小票纸")
            : options.paper.shortLabel

        let result = NSMutableAttributedString()
        result.append(TextLayout.styled("局域网打印\n", font: title))
        result.append(TextLayout.styled("打印测试页\n", font: subtitle))
        result.append(TextLayout.styled("\n", font: body))

        let lines = [
            "打印机：\(printer.displayName)",
            "地址：\(printer.endpoint)",
            "协议：\(printer.proto.shortLabel)",
            "格式：\(format.shortLabel)",
            "纸张：\(paperText) · 份数：\(options.clampedCopies)",
            "时间：\(now.string(from: Date()))",
            "",
            String(repeating: "-", count: compact ? 24 : 56),
            "本行用于测试对齐与换行：",
            "1234567890 ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            "abcdefghijklmnopqrstuvwxyz",
            "中文对齐测试：打印机测试页 0123456789",
            "■ ● ▲ 对齐标记",
            String(repeating: "-", count: compact ? 24 : 56),
            "",
            "如果你能看到这一页，说明",
            "手机 → 打印机 链路正常。"
        ]
        result.append(TextLayout.styled(lines.joined(separator: "\n"), font: body))
        return result
    }

    /// 普通文本（txt / md / csv 等）。
    static func plainText(_ text: String, dpi: CGFloat) -> NSAttributedString {
        let font = TextLayout.monoFont(dpi: dpi, pointSize: 11)
        return TextLayout.styled(text, font: font)
    }

    static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        if let s = String(data: data, encoding: .utf16), !s.isEmpty { return s }

        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)), !s.isEmpty {
            return s
        }
        if let s = String(data: data, encoding: .isoLatin1), !s.isEmpty { return s }
        return nil
    }
}
