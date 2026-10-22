import Foundation
import UIKit
import PDFKit

/// 把「内容来源」变成「打印机认识的字节」。
enum PrintPipeline {

    static func buildPayload(
        printer: PrinterConfig,
        source: PrintSource,
        options: PrintOptions,
        log: @escaping (PrintLogEntry.Level, String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws -> Data {
        if printer.format.isReceipt {
            return try await buildReceipt(
                printer: printer,
                source: source,
                options: options,
                log: log,
                progress: progress
            )
        }
        if printer.format == .pdf {
            return try await buildPDF(
                printer: printer,
                source: source,
                options: options,
                log: log,
                progress: progress
            )
        }
        return try await buildPCL(
            printer: printer,
            source: source,
            options: options,
            log: log,
            progress: progress
        )
    }

    // MARK: - PCL 光栅

    private static func buildPCL(
        printer: PrinterConfig,
        source: PrintSource,
        options: PrintOptions,
        log: @escaping (PrintLogEntry.Level, String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws -> Data {
        var paper = options.paper
        if paper.isReceipt {
            paper = .a4
            log(.warning, "PCL 不能打印连续小票纸，已按 A4 排版；需要小票请把格式改成 ESC/POS。")
        }

        let mm = paper.sizeMM(
            customWidth: options.customWidthMM,
            customHeight: options.customHeightMM
        )
        let geometry = PageGeometry(paperMM: mm, dpi: CGFloat(PCLRaster.defaultDPI))
        let prepared = try await prepare(
            source: source,
            printer: printer,
            options: options,
            dpi: geometry.dpi,
            log: log
        )
        let document = PageDocument(prepared: prepared, geometry: geometry)

        let copies = printer.proto == .ipp ? 1 : max(1, min(options.copies, 99))
        let totalPages = max(1, document.pageCount * copies)

        if printer.proto == .ipp {
            log(.info, "页面 \(document.pageCount) 页 · 份数由 IPP 属性传递")
        } else {
            log(.info, "页面 \(document.pageCount) 页 × \(copies) 份")
        }
        log(.info, "纸张 \(Int(mm.width.rounded())) × \(Int(mm.height.rounded())) mm · 300 dpi · \(geometry.pixelWidth) × \(geometry.pixelHeight) px")

        var output = Data()
        var rendered = 0

        for _ in 0..<copies {
            output.append(PCLRaster.jobHeader(paper: paper))
            for index in 0..<document.pageCount {
                if Task.isCancelled { throw CancellationError() }
                let image = document.renderPage(index)
                output.append(
                    PCLRaster.page(
                        image: image,
                        width: geometry.pixelWidth,
                        height: geometry.pixelHeight
                    )
                )
                rendered += 1
                progress(0.05 + 0.50 * Double(rendered) / Double(totalPages))
            }
            output.append(PCLRaster.jobFooter())
        }

        return output
    }

    // MARK: - 小票 ESC/POS

    private static func buildReceipt(
        printer: PrinterConfig,
        source: PrintSource,
        options: PrintOptions,
        log: @escaping (PrintLogEntry.Level, String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws -> Data {
        let widthDots = ESCPOS.widthDots(for: printer.format)
        let copies = max(1, min(options.copies, 99))

        let prepared = try await prepare(
            source: source,
            printer: printer,
            options: options,
            dpi: 203,
            log: log
        )
        let image = try receiptImage(prepared: prepared, widthDots: widthDots, log: log)
        progress(0.5)

        log(.info, "小票 \(widthDots) 点宽 × \(max(1, Int(image.size.height.rounded()))) 点高 × \(copies) 份")
        return ESCPOS.encode(image: image, widthDots: widthDots, copies: copies)
    }

    private static func receiptImage(
        prepared: PreparedSource,
        widthDots: Int,
        log: @escaping (PrintLogEntry.Level, String) -> Void
    ) throws -> UIImage {
        let margin = widthDots == 384 ? 12 : 16

        switch prepared {
        case .text(let attr):
            return TextLayout.renderTall(
                attr,
                width: widthDots,
                margin: margin,
                maxHeight: 30000
            )
        case .image(let image):
            return stackImages([image], width: widthDots)
        case .pdf(let document):
            var pages: [UIImage] = []
            let count = min(document.pageCount, 12)
            for index in 0..<count {
                guard let page = document.page(at: index) else { continue }
                pages.append(renderPDFPageToWidth(page, width: widthDots))
            }
            if count < document.pageCount {
                log(.warning, "小票模式最多输出 12 页，已截取前 \(count) 页。")
            }
            return stackImages(pages, width: widthDots)
        }
    }

    private static func renderPDFPageToWidth(_ page: PDFPage, width: Int) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let ratio = bounds.width > 0 ? bounds.height / bounds.width : 1.4
        let height = max(1, min(30000, Int((ratio * CGFloat(width)).rounded())))
        let size = CGSize(width: width, height: height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            guard bounds.width > 0 else { return }

            let scale = CGFloat(width) / bounds.width
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: cg)
        }
    }

    private static func stackImages(_ images: [UIImage], width: Int) -> UIImage {
        let gap = 10
        var heights: [Int] = []
        var total = 0

        for image in images {
            let ratio = image.size.width > 0 ? image.size.height / image.size.width : 1.4
            let h = max(1, Int((ratio * CGFloat(width)).rounded()))
            heights.append(h)
            total += h
        }
        total += gap * max(0, images.count - 1)
        let height = min(30000, max(120, total))

        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))

            var y: CGFloat = 0
            for (index, image) in images.enumerated() {
                if y >= CGFloat(height) { break }
                let h = heights[index]
                image.draw(in: CGRect(x: 0, y: y, width: CGFloat(width), height: CGFloat(h)))
                y += CGFloat(h + gap)
            }
        }
    }

    // MARK: - PDF（IPP）

    private static func buildPDF(
        printer: PrinterConfig,
        source: PrintSource,
        options: PrintOptions,
        log: @escaping (PrintLogEntry.Level, String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws -> Data {
        // PDF 原件 / 网页直接转出的 PDF：不重新排版
        switch source {
        case .file(let url) where url.pathExtension.lowercased() == "pdf":
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { throw PrintSourceError.emptyFile }
            log(.info, "直接发送 PDF 原件（\(Format.bytes(data.count))）")
            progress(0.5)
            return data

        case .file(let url) where ["html", "htm"].contains(url.pathExtension.lowercased()):
            let data = try await WebPDFLoader.load(fileURL: url)
            log(.success, "网页文件已转成 PDF（\(Format.bytes(data.count))）")
            progress(0.5)
            return data

        case .web(let raw):
            let data = try await WebPDFLoader.load(urlString: raw)
            log(.success, "网页已转成 PDF（\(Format.bytes(data.count))）")
            progress(0.5)
            return data

        default:
            break
        }

        var paper = options.paper
        if paper.isReceipt {
            paper = .a4
            log(.warning, "PDF 直传不支持连续小票纸，已按 A4 排版。")
        }
        let mm = paper.sizeMM(
            customWidth: options.customWidthMM,
            customHeight: options.customHeightMM
        )
        let geometry = PageGeometry(paperMM: mm, dpi: 150)
        let prepared = try await prepare(
            source: source,
            printer: printer,
            options: options,
            dpi: 150,
            log: log
        )
        let document = PageDocument(prepared: prepared, geometry: geometry)

        log(.info, "生成 PDF：\(document.pageCount) 页 · \(Int(mm.width.rounded())) × \(Int(mm.height.rounded())) mm")

        let pageSize = CGSize(width: mm.width / 25.4 * 72, height: mm.height / 25.4 * 72)
        let bounds = CGRect(origin: .zero, size: pageSize)
        let total = max(1, document.pageCount)

        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 0..<document.pageCount {
                context.beginPage()
                UIColor.white.setFill()
                context.cgContext.fill(bounds)
                let image = document.renderPage(index)
                image.draw(in: bounds)
                progress(0.05 + 0.45 * Double(index + 1) / Double(total))
            }
        }

        return data
    }

    // MARK: - 解析来源

    private static func prepare(
        source: PrintSource,
        printer: PrinterConfig,
        options: PrintOptions,
        dpi: CGFloat,
        log: @escaping (PrintLogEntry.Level, String) -> Void
    ) async throws -> PreparedSource {
        switch source {
        case .test:
            return .text(
                PrintContent.testPage(
                    printer: printer,
                    options: options,
                    format: printer.format,
                    dpi: dpi
                )
            )

        case .file(let url):
            return try await prepareFile(url: url, dpi: dpi, log: log)

        case .web(let raw):
            let data = try await WebPDFLoader.load(urlString: raw)
            guard let document = PDFDocument(data: data) else {
                throw PrintSourceError.badPDF
            }
            log(.success, "网页已转成 PDF（\(document.pageCount) 页）")
            return .pdf(document)
        }
    }

    private static func prepareFile(
        url: URL,
        dpi: CGFloat,
        log: @escaping (PrintLogEntry.Level, String) -> Void
    ) async throws -> PreparedSource {
        let ext = url.pathExtension.lowercased()

        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else {
                throw PrintSourceError.badPDF
            }
            log(.info, "PDF：\(document.pageCount) 页")
            return .pdf(document)
        }

        if ["html", "htm"].contains(ext) {
            let data = try await WebPDFLoader.load(fileURL: url)
            guard let document = PDFDocument(data: data) else {
                throw PrintSourceError.badPDF
            }
            log(.success, "网页文件已转成 PDF（\(document.pageCount) 页）")
            return .pdf(document)
        }

        if ["png", "jpg", "jpeg", "heic", "gif", "bmp", "tiff", "webp"].contains(ext) {
            guard let image = UIImage(contentsOfFile: url.path) else {
                throw PrintSourceError.badImage
            }
            log(.info, "图片：\(Int(image.size.width)) × \(Int(image.size.height)) px")
            return .image(image)
        }

        if ["txt", "md", "csv", "log", "json", "xml", "ini", "conf", "text"].contains(ext) {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { throw PrintSourceError.emptyFile }
            guard let text = PrintContent.decodeText(data) else {
                throw PrintSourceError.badText
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PrintSourceError.emptyText
            }
            log(.info, "文本：\(text.count) 字")
            return .text(PrintContent.plainText(text, dpi: dpi))
        }

        throw PrintSourceError.unsupported(ext.isEmpty ? "未知" : ext)
    }
}
