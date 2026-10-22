import Foundation
import CoreGraphics

// MARK: - 协议

/// 与 Android 版一致的三种局域网打印协议。
enum PrinterProtocol: String, CaseIterable, Identifiable, Codable, Hashable {
    case raw
    case lpr
    case ipp

    var id: String { rawValue }

    /// 底部列表 / 胶囊里用的短名。
    var shortLabel: String {
        switch self {
        case .raw: return "RAW 9100"
        case .lpr: return "LPR 515"
        case .ipp: return "IPP 631"
        }
    }

    /// 表单下拉里的完整名称。
    var label: String {
        switch self {
        case .raw: return "RAW 9100（最通用，旧打印机首选）"
        case .lpr: return "LPR / LPD 515（端口 515）"
        case .ipp: return "IPP 631（基于 HTTP）"
        }
    }

    var defaultPort: Int {
        switch self {
        case .raw: return 9100
        case .lpr: return 515
        case .ipp: return 631
        }
    }

    var hint: String {
        switch self {
        case .raw:
            return "直接把打印数据推到 9100 端口，绝大多数网络打印机都支持。"
        case .lpr:
            return "通过 LPD 队列提交，需要填写队列名（一般为 lp）。"
        case .ipp:
            return "走 HTTP 的 IPP 打印，适合支持 IPP 的打印机或打印服务器。"
        }
    }

    /// 该协议可用的输出格式。
    var supportedFormats: [PrintFormat] {
        switch self {
        case .raw:
            // 电脑桥接只能走 RAW 9100，且必须由电脑端桥接程序转发。
            return [.pcl, .bridge, .esc58, .esc80]
        case .lpr:
            return [.pcl, .esc58, .esc80]
        case .ipp:
            return [.pcl, .pdf]
        }
    }
}

// MARK: - 输出格式

enum PrintFormat: String, CaseIterable, Identifiable, Codable, Hashable {
    case pcl
    case pdf
    case esc58
    case esc80
    case bridge

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .pcl: return "光栅 PCL"
        case .pdf: return "PDF"
        case .esc58: return "小票 58mm"
        case .esc80: return "小票 80mm"
        case .bridge: return "电脑桥接"
        }
    }

    var label: String {
        switch self {
        case .pcl: return "PCL5 光栅（HP 及兼容激光打印机）"
        case .pdf: return "PDF 直传（IPP 彩色 / 软件 RIP）"
        case .esc58: return "ESC/POS 热敏小票 58mm"
        case .esc80: return "ESC/POS 热敏小票 80mm"
        case .bridge: return "电脑桥接直传（打印电脑上安装的任意打印机）"
        }
    }

    var hint: String {
        switch self {
        case .pcl:
            return "本机把每一页渲染成黑白位图，再用 PCL5 光栅指令发送，兼容性最好。"
        case .pdf:
            return "只用于 IPP：内容以 PDF 直传打印机，适合支持 PDF 的彩色激光 / 软件 RIP 设备。"
        case .esc58:
            return "按 58mm 热敏小票机输出（384 点宽），内容自动缩放到纸宽。"
        case .esc80:
            return "按 80mm 热敏小票机输出（576 点宽），内容自动缩放到纸宽。"
        case .bridge:
            return "先把电脑上的桥接程序打开，再连接电脑 IP 的 9100 端口；可打印电脑上安装的任意打印机（包括 GDI 打印机）。"
        }
    }

    var isReceipt: Bool { self == .esc58 || self == .esc80 }

    /// MIME 类型（用于 IPP 的 document-format）。
    var mimeType: String {
        switch self {
        case .pcl: return "application/vnd.hp-PCL"
        case .pdf: return "application/pdf"
        case .esc58, .esc80, .bridge: return "application/octet-stream"
        }
    }
}

// MARK: - 纸张

enum PaperSize: String, CaseIterable, Identifiable, Codable, Hashable {
    case a4
    case a5
    case letter
    case receipt58
    case receipt80
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a4: return "A4（210 × 297 mm）"
        case .a5: return "A5（148 × 210 mm）"
        case .letter: return "Letter（216 × 279 mm）"
        case .receipt58: return "小票 58mm（连续纸）"
        case .receipt80: return "小票 80mm（连续纸）"
        case .custom: return "自定义（mm）"
        }
    }

    var shortLabel: String {
        switch self {
        case .a4: return "A4"
        case .a5: return "A5"
        case .letter: return "Letter"
        case .receipt58: return "58mm"
        case .receipt80: return "80mm"
        case .custom: return "自定义"
        }
    }

    /// 物理尺寸（mm）。小票纸高度为 0，表示连续纸。
    func sizeMM(customWidth: Double, customHeight: Double) -> CGSize {
        switch self {
        case .a4: return CGSize(width: 210, height: 297)
        case .a5: return CGSize(width: 148, height: 210)
        case .letter: return CGSize(width: 215.9, height: 279.4)
        case .receipt58: return CGSize(width: 58, height: 0)
        case .receipt80: return CGSize(width: 80, height: 0)
        case .custom:
            return CGSize(
                width: max(20, min(customWidth, 500)),
                height: max(20, min(customHeight, 1000))
            )
        }
    }

    var isReceipt: Bool { self == .receipt58 || self == .receipt80 }
}

// MARK: - 打印机配置

struct PrinterConfig: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 9100
    var proto: PrinterProtocol = .raw
    var format: PrintFormat = .pcl
    var paper: PaperSize = .a4
    var customWidthMM: Double = 100
    var customHeightMM: Double = 150
    var queue: String = "lp"
    var ippPath: String = "/ipp/print"

    var createdAt: Date = Date()
    var lastTestAt: Date? = nil
    var lastTestOK: Bool? = nil
    var lastTestDetail: String? = nil
    var lastPrintAt: Date? = nil

    var endpoint: String { "\(host):\(port)" }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }

    var paperMM: CGSize {
        paper.sizeMM(customWidth: customWidthMM, customHeight: customHeightMM)
    }

    /// 首页卡片、打印页上展示的「连接方式」。
    var connectionLabel: String {
        format == .bridge ? "电脑桥接" : "Wi-Fi 局域网直连"
    }

    var connectionIcon: String {
        format == .bridge ? "desktopcomputer" : "wifi"
    }

    /// 保留协议支持的格式；协议变更后调用，避免出现 RAW + PDF 这种组合。
    mutating func normalizeFormat() {
        // 电脑桥接固定走 RAW 9100；选择桥接后不再允许 LPR / IPP。
        if format == .bridge {
            proto = .raw
            port = 9100
        } else if !proto.supportedFormats.contains(format) {
            format = proto.supportedFormats.first ?? .pcl
        }
        if !format.isReceipt && paper.isReceipt {
            paper = .a4
        }
        if port < 1 || port > 65535 {
            port = proto.defaultPort
        }
        if queue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queue = "lp"
        }
        if !ippPath.hasPrefix("/") {
            ippPath = "/" + ippPath
        }
    }

    static func make(protocol proto: PrinterProtocol, host: String, name: String = "") -> PrinterConfig {
        var p = PrinterConfig()
        p.proto = proto
        p.host = host
        p.name = name
        p.port = proto.defaultPort
        p.format = proto.supportedFormats.first ?? .pcl
        p.normalizeFormat()
        return p
    }
}

// MARK: - 打印选项

struct PrintOptions: Equatable {
    var copies: Int = 1
    var paper: PaperSize
    var customWidthMM: Double
    var customHeightMM: Double

    init(printer: PrinterConfig) {
        paper = printer.paper
        customWidthMM = printer.customWidthMM
        customHeightMM = printer.customHeightMM
    }

    var paperMM: CGSize {
        paper.sizeMM(customWidth: customWidthMM, customHeight: customHeightMM)
    }

    var clampedCopies: Int { max(1, min(copies, 99)) }
}

// MARK: - 扫描结果

struct ScanResult: Identifiable, Hashable {
    let host: String
    let port: Int
    var proto: PrinterProtocol
    var format: PrintFormat = .pcl
    var detail: String

    var id: String { "\(host):\(port)" }
    var isBridge: Bool { format == .bridge }
}

// MARK: - 打印日志

struct PrintLogEntry: Identifiable, Equatable {
    enum Level: String {
        case info
        case success
        case warning
        case error
    }

    let id = UUID()
    let time: Date
    let level: Level
    let text: String

    init(_ text: String, level: Level = .info) {
        self.time = Date()
        self.level = level
        self.text = text
    }

    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: time)
    }
}

// MARK: - 地址解析

enum HostPort {
    /// 支持 "192.168.1.10"、"192.168.1.10:9100"、"printer.local:631"。
    static func split(_ raw: String) -> (host: String, port: Int?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("", nil) }

        // IPv6 字面量：[fe80::1]:9100
        if text.hasPrefix("[") {
            if let close = text.firstIndex(of: "]") {
                let host = String(text[text.index(after: text.startIndex)..<close])
                let rest = text[text.index(after: close)...]
                if rest.hasPrefix(":") {
                    return (host, Int(rest.dropFirst()))
                }
                return (host, nil)
            }
        }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let p = Int(parts[1]) {
            return (String(parts[0]), p)
        }
        return (text, nil)
    }

    static func isValidHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return false }
        if h.contains(" ") { return false }
        // 允许 IPv4、主机名、IPv6（不含冒号时简单校验）
        if h.contains(":") { return true }
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9\-\._]*$"#
        return h.range(of: pattern, options: .regularExpression) != nil
    }
}
