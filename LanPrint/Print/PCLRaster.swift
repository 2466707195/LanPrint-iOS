import Foundation
import UIKit
import CoreGraphics

/// PCL5 光栅编码（黑白）。
///
/// 序列（每份任务）：
///   ESC E            复位
///   ESC &l<code>A    纸张（A4 / A5 / Letter）
///   ESC &l0O         纵向
///   ESC *t300R       300 dpi
///   ESC *r0F         光栅呈现模式
/// 每页：
///   ESC *r1A         开始光栅
///   ESC *b0M         不压缩
///   ESC *b<n>W<data> 逐行发送
///   ESC *rB          结束光栅
///   ESC &l0H         纸盒自动
enum PCLRaster {

    static let defaultDPI = 300

    // MARK: 任务头尾

    static func jobHeader(paper: PaperSize, dpi: Int = defaultDPI) -> Data {
        var data = Data()
        data.append(contentsOf: [0x1B, 0x45])                    // ESC E
        if let code = paperCode(paper) {
            data.appendASCII("\u{1B}&l\(code)A")                 // 纸张
        }
        data.appendASCII("\u{1B}&l0O")                           // 纵向
        data.appendASCII("\u{1B}*t\(dpi)R")                      // 分辨率
        data.appendASCII("\u{1B}*r0F")                           // 光栅呈现模式
        return data
    }

    static func jobFooter() -> Data {
        var data = Data()
        data.append(contentsOf: [0x1B, 0x45])
        return data
    }

    private static func paperCode(_ paper: PaperSize) -> Int? {
        switch paper {
        case .a4: return 26
        case .a5: return 25
        case .letter: return 2
        default: return nil
        }
    }

    // MARK: 单页

    static func page(image: UIImage, width: Int, height: Int) -> Data {
        let rowBytes = (width + 7) / 8
        var data = Data()
        data.appendASCII("\u{1B}*r1A")                           // 开始光栅
        data.appendASCII("\u{1B}*b0M")                           // 不压缩
        let bits = packMono(image: image, width: width, height: height, rowBytes: rowBytes)
        let prefix = "\u{1B}*b\(rowBytes)W"
        let prefixData = Data(prefix.utf8)

        data.reserveCapacity(bits.count + height * prefixData.count + 16)
        for row in 0..<height {
            data.append(prefixData)
            let start = row * rowBytes
            data.append(contentsOf: bits[start..<(start + rowBytes)])
        }

        data.appendASCII("\u{1B}*rB")                            // 结束光栅
        data.appendASCII("\u{1B}&l0H")                           // 纸盒自动
        return data
    }

    // MARK: 位图打包

    /// 8×8 Bayer 抖动矩阵（与 Android 版 Driver.BAYER 一致）。
    private static let bayer: [UInt8] = [
        0, 32, 8, 40, 2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37,
        63, 31, 55, 23, 61, 29, 53, 21
    ]

    /// 把整页图片转成 1bpp、行优先、MSB 在前的数据（1 = 黑）。
    static func packMono(image: UIImage, width: Int, height: Int, rowBytes: Int) -> [UInt8] {
        var gray = [UInt8](repeating: 255, count: width * height)

        gray.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            let colorSpace = CGColorSpaceCreateDeviceGray()
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }

            context.interpolationQuality = .high
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let cgImage = image.cgImage {
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        var out = [UInt8](repeating: 0, count: rowBytes * height)

        for y in 0..<height {
            let src = y * width
            let dst = y * rowBytes
            let rowBase = (y & 7) * 8
            for x in 0..<width {
                let threshold = Int(bayer[rowBase + (x & 7)]) * 4 + 2
                if Int(gray[src + x]) < threshold {
                    out[dst + (x >> 3)] |= UInt8(0x80 >> (x & 7))
                }
            }
        }
        return out
    }
}

// MARK: - Data 小工具

extension Data {
    mutating func appendASCII(_ text: String) {
        append(contentsOf: text.utf8)
    }

    mutating func appendByte(_ value: UInt8) {
        append(value)
    }
}
