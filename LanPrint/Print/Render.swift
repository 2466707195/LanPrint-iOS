import Foundation
import UIKit
import PDFKit
import CoreText

// MARK: - 页面几何

/// 把纸张 mm 尺寸换算成打印像素。
struct PageGeometry {

    let paperMM: CGSize
    let dpi: CGFloat
    let marginMM: CGFloat

    init(paperMM: CGSize, dpi: CGFloat, marginMM: CGFloat = 5) {
        self.paperMM = paperMM
        self.dpi = dpi
        self.marginMM = marginMM
    }

    var pixelSize: CGSize {
        CGSize(
            width: max(64, (paperMM.width / 25.4 * dpi).rounded()),
            height: max(64, (paperMM.height / 25.4 * dpi).rounded())
        )
    }

    var pixelWidth: Int { Int(pixelSize.width) }
    var pixelHeight: Int { Int(pixelSize.height) }

    var margin: CGFloat { marginMM / 25.4 * dpi }

    var contentRect: CGRect {
        CGRect(
            x: margin,
            y: margin,
            width: max(8, pixelSize.width - margin * 2),
            height: max(8, pixelSize.height - margin * 2)
        )
    }

    var contentSize: CGSize { contentRect.size }
}

// MARK: - 文本排版

enum TextLayout {

    static func font(dpi: CGFloat, pointSize: CGFloat = 12, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.systemFont(ofSize: pointSize * dpi / 72, weight: weight)
    }

    static func monoFont(dpi: CGFloat, pointSize: CGFloat = 11) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: pointSize * dpi / 72, weight: .regular)
    }

    static func styled(_ text: String, font: UIFont, color: UIColor = .black) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = font.pointSize * 0.30
        style.paragraphSpacing = font.pointSize * 0.18
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style
            ]
        )
    }

    /// 按页面内容区高度分页，返回每页对应的字符范围。
    static func paginate(_ attr: NSAttributedString, contentSize: CGSize) -> [CFRange] {
        guard attr.length > 0 else { return [CFRange(location: 0, length: 0)] }
        let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        var ranges: [CFRange] = []
        var location = 0

        while location < attr.length {
            let path = CGPath(
                rect: CGRect(origin: .zero, size: contentSize),
                transform: nil
            )
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 { break }
            ranges.append(visible)
            location += visible.length
            if ranges.count > 200 { break }
        }

        return ranges.isEmpty ? [CFRange(location: 0, length: 0)] : ranges
    }

    /// 把指定范围的文字画到整页白底上。
    static func renderPage(
        _ attr: NSAttributedString,
        range: CFRange,
        geometry: PageGeometry
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: geometry.pixelSize, format: format)

        return renderer.image { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: geometry.pixelSize))

            cg.saveGState()
            cg.textMatrix = .identity
            cg.translateBy(x: 0, y: geometry.pixelSize.height)
            cg.scaleBy(x: 1, y: -1)
            let path = CGPath(rect: geometry.contentRect, transform: nil)
            let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, cg)
            cg.restoreGState()
        }
    }

    /// 连续纸（小票）用的任意高度文本图。
    static func renderTall(
        _ attr: NSAttributedString,
        width: Int,
        margin: Int,
        maxHeight: Int
    ) -> UIImage {
        let contentWidth = max(32, width - margin * 2)
        let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        var fit = CFRange()
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: contentWidth, height: CGFloat(maxHeight)),
            &fit
        )
        let height = min(maxHeight, max(120, Int(ceil(measured.height)) + margin * 2))
        let size = CGSize(width: width, height: height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            cg.saveGState()
            cg.textMatrix = .identity
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            let path = CGPath(
                rect: CGRect(
                    x: margin,
                    y: margin,
                    width: contentWidth,
                    height: max(16, height - margin * 2)
                ),
                transform: nil
            )
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, cg)
            cg.restoreGState()
        }
    }

    /// 把图片按比例放进页面内容区，白底居中。
    static func renderImage(_ image: UIImage, geometry: PageGeometry) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: geometry.pixelSize, format: format)

        return renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: geometry.pixelSize))

            let target = Self.aspectFit(
                size: image.size,
                into: geometry.contentRect
            )
            image.draw(in: target)
        }
    }

    static func aspectFit(size: CGSize, into rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }
}

// MARK: - 已解析的文档

enum PreparedSource {
    case pdf(PDFDocument)
    case image(UIImage)
    case text(NSAttributedString)
}

/// 按页输出图片；文本先分页，PDF 按纸张宽度铺满、纵向切片。
final class PageDocument {

    private enum Kind {
        case pdf(PDFDocument)
        case image(UIImage)
        case text(NSAttributedString)
    }

    private struct PDFSlice {
        let pageIndex: Int
        let scale: CGFloat
        let offset: CGFloat
        let bounds: CGRect
    }

    private let kind: Kind
    private let geometry: PageGeometry
    private let textRanges: [CFRange]
    private var pdfSlices: [PDFSlice] = []

    init(prepared: PreparedSource, geometry: PageGeometry) {
        self.geometry = geometry

        switch prepared {
        case .pdf(let document):
            kind = .pdf(document)
            textRanges = []

            let sliceHeight = max(1, geometry.contentRect.height)
            var slices: [PDFSlice] = []

            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width > 0, bounds.height > 0 else { continue }

                let scale = geometry.contentRect.width / bounds.width
                let scaledHeight = bounds.height * scale
                let count = max(1, Int(ceil(scaledHeight / sliceHeight)))

                for slice in 0..<count {
                    slices.append(
                        PDFSlice(
                            pageIndex: index,
                            scale: scale,
                            offset: CGFloat(slice) * sliceHeight,
                            bounds: bounds
                        )
                    )
                }
            }
            pdfSlices = slices

        case .image(let image):
            kind = .image(image)
            textRanges = []

        case .text(let attr):
            kind = .text(attr)
            textRanges = TextLayout.paginate(attr, contentSize: geometry.contentSize)
        }
    }

    var pageCount: Int {
        switch kind {
        case .pdf: return max(1, pdfSlices.count)
        case .image: return 1
        case .text: return max(1, textRanges.count)
        }
    }

    func renderPage(_ index: Int) -> UIImage {
        switch kind {
        case .pdf(let document):
            guard !pdfSlices.isEmpty else { return blankPage() }
            let slice = pdfSlices[max(0, min(index, pdfSlices.count - 1))]
            guard let page = document.page(at: slice.pageIndex) else { return blankPage() }
            return renderPDFSlice(page: page, slice: slice)

        case .image(let image):
            return TextLayout.renderImage(image, geometry: geometry)

        case .text(let attr):
            let range = textRanges[max(0, min(index, textRanges.count - 1))]
            return TextLayout.renderPage(attr, range: range, geometry: geometry)
        }
    }

    // MARK: PDF

    private func renderPDFSlice(page: PDFPage, slice: PDFSlice) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: geometry.pixelSize, format: format)
        let bounds = slice.bounds

        return renderer.image { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: geometry.pixelSize))

            let targetHeight = bounds.height * slice.scale
            let target = CGRect(
                x: geometry.contentRect.minX,
                y: geometry.contentRect.minY - slice.offset,
                width: geometry.contentRect.width,
                height: targetHeight
            )

            cg.saveGState()
            cg.translateBy(x: target.minX, y: target.maxY)
            cg.scaleBy(x: slice.scale, y: -slice.scale)
            cg.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
    }

    private func blankPage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: geometry.pixelSize, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: geometry.pixelSize))
        }
    }
}
