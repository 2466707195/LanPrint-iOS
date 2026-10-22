import Foundation
import UIKit

/// ESC/POS 热敏小票光栅编码。
///
/// 58mm 纸：384 点宽；80mm 纸：576 点宽。
/// 命令：ESC @ 初始化 → GS v 0 光栅 → ESC d 走纸 → GS V 切纸。
enum ESCPOS {

    static func widthDots(for format: PrintFormat) -> Int {
        format == .esc80 ? 576 : 384
    }

    static func encode(image: UIImage, widthDots: Int, copies: Int) -> Data {
        let safeWidth = max(64, (widthDots / 8) * 8)
        let height = min(30000, max(1, Int(image.size.height.rounded())))
        let bytesPerRow = safeWidth / 8

        let bits = PCLRaster.packMono(
            image: image,
            width: safeWidth,
            height: height,
            rowBytes: bytesPerRow
        )

        var data = Data()
        data.append(contentsOf: [0x1B, 0x40])                    // ESC @

        for _ in 0..<max(1, copies) {
            data.append(contentsOf: [0x1D, 0x76, 0x30, 0x00])    // GS v 0 m=0
            data.append(UInt8(bytesPerRow & 0xFF))
            data.append(UInt8((bytesPerRow >> 8) & 0xFF))
            data.append(UInt8(height & 0xFF))
            data.append(UInt8((height >> 8) & 0xFF))
            data.append(bits)
            data.append(contentsOf: [0x1B, 0x64, 0x04])          // ESC d 4（走纸 4 行）
        }

        data.append(contentsOf: [0x1D, 0x56, 0x42, 0x00])        // GS V B 0（切纸）
        return data
    }
}
