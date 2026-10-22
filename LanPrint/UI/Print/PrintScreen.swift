import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct PrintScreen: View {

    @EnvironmentObject private var store: PrinterStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var runner = PrintJobRunner()

    @State private var config: PrinterConfig
    @State private var options: PrintOptions
    @State private var tab: SourceTab = .test
    @State private var selectedFile: URL?
    @State private var fileSizeText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoURL: URL?
    @State private var photoPreview: UIImage?
    @State private var photoInfo = ""
    @State private var webURL = ""
    @State private var widthText: String
    @State private var heightText: String
    @State private var showFileImporter = false
    @State private var fileError: String?
    @State private var testing = false
    @State private var testDetail: String?
    @State private var testOK = false

    init(printer: PrinterConfig) {
        _config = State(initialValue: printer)
        _options = State(initialValue: PrintOptions(printer: printer))
        _widthText = State(initialValue: String(format: "%.0f", printer.customWidthMM))
        _heightText = State(initialValue: String(format: "%.0f", printer.customHeightMM))
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            AuroraBackdrop()

            VStack(spacing: 0) {
                AppTopBar(
                    title: "打印",
                    subtitle: "\(config.displayName) · \(config.endpoint)",
                    onBack: { dismiss() }
                )
                content
            }

            bottomBar
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importFile(url) }
            case .failure(let error):
                fileError = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .onChange(of: widthText) { value in
            if let width = Double(value) { options.customWidthMM = width }
        }
        .onChange(of: heightText) { value in
            if let height = Double(value) { options.customHeightMM = height }
        }
        .onChange(of: photoItem) { item in
            loadPhoto(item)
        }
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                printerCard
                sourceCard
                settingsCard
                if runner.isRunning || runner.finished || !runner.logs.isEmpty {
                    progressCard
                }
                if let fileError {
                    messageCard(fileError, ok: false)
                }
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, AuroraMetrics.listBottomInset)
        }
        .scrollIndicators(.hidden)
    }

    private var printerCard: some View {
        SectionCard {
            HStack(spacing: 12) {
                Monogram(name: config.displayName, tone: Aurora.brand)

                VStack(alignment: .leading, spacing: 4) {
                    Text(config.displayName)
                        .font(AuroraFont.titleMedium)
                        .foregroundStyle(Aurora.ink)
                        .lineLimit(1)
                    Text(config.endpoint)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: config.connectionIcon)
                            .font(.system(size: 10, weight: .semibold))
                        Text("连接方式：\(config.connectionLabel)")
                            .font(AuroraFont.labelSmall)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Aurora.muted)
                }

                Spacer(minLength: 4)

                SmallTonalButton(
                    text: testing ? "测试中…" : "测试",
                    systemIcon: "bolt.horizontal",
                    enabled: !testing && !runner.isRunning
                ) {
                    runTest()
                }
            }

            HStack(spacing: 6) {
                StatusPill(text: config.proto.shortLabel, color: Aurora.brand)
                StatusPill(
                    text: config.format.shortLabel,
                    color: config.format == .bridge ? Aurora.rose : Aurora.teal
                )
                StatusPill(text: paperLabel, color: Aurora.muted)
            }
            .padding(.top, 10)

            if let testDetail {
                Text(testDetail)
                    .font(AuroraFont.labelSmall)
                    .foregroundStyle(testOK ? Aurora.success : Aurora.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    private var sourceCard: some View {
        SectionCard {
            Text("内容")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
                .padding(.bottom, 10)

            AuroraSegmented(options: SourceTab.allCases, selection: $tab) { $0.label }
                .padding(.bottom, 12)

            switch tab {
            case .test:
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(
                        systemIcon: "doc.text",
                        text: "打印一页内置测试页：包含打印机信息、对齐与换行测试，用来确认手机到打印机的链路。"
                    )
                    InfoRow(
                        systemIcon: "checkmark.seal",
                        text: "新添加打印机后，建议先打一张测试页。"
                    )
                }
                .padding(.bottom, 2)

            case .file:
                fileSection

            case .photo:
                photoSection

            case .web:
                VStack(alignment: .leading, spacing: 10) {
                    LabeledField(
                        title: "网页地址",
                        hint: "会自动补全 http://；网页先在本机转成 PDF，再按纸张分页。"
                    ) {
                        AuroraTextField(
                            placeholder: "example.com",
                            text: $webURL,
                            systemIcon: "globe",
                            keyboardType: .URL
                        )
                    }

                    InfoRow(
                        systemIcon: "lock.shield",
                        text: "网页只在本机加载和排版，不会上传到云端。"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        if let file = selectedFile {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Aurora.teal.tint(0.13))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: fileIcon(file))
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(Aurora.teal)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(file.lastPathComponent)
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.ink)
                        .lineLimit(1)
                    Text("\(kindLabel(file))\(fileSizeText.isEmpty ? "" : " · \(fileSizeText)")")
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                }

                Spacer(minLength: 4)

                Button {
                    selectedFile = nil
                    fileSizeText = ""
                    fileError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(Aurora.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 10)

            TonalButton(text: "重新选择文件", systemIcon: "folder") {
                showFileImporter = true
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                TonalButton(text: "选择文件", systemIcon: "folder") {
                    showFileImporter = true
                }
                InfoRow(
                    systemIcon: "doc.on.doc",
                    text: "支持 PDF、图片（PNG / JPG / HEIC）和 txt / md / csv 等文本文件。"
                )
            }
        }
    }

    @ViewBuilder
    private var photoSection: some View {
        if let photoURL, let photoPreview {
            HStack(spacing: 12) {
                Image(uiImage: photoPreview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(photoURL.lastPathComponent)
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.ink)
                        .lineLimit(1)
                    Text(photoInfo.isEmpty ? "相册图片" : photoInfo)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    clearPhoto()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(Aurora.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 10)

            photoPickerButton(title: "重新选择图片")

            InfoRow(
                systemIcon: "lock.shield",
                text: "照片只在本机读取和排版，不会上传；打印时会按所选纸张自动缩放。"
            )
            .padding(.top, 10)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                photoPickerButton(title: "从相册选择图片")

                InfoRow(
                    systemIcon: "photo.on.rectangle.angled",
                    text: "直接从系统相册选择 PNG / JPG / HEIC，按图片原始比例排版。"
                )
                InfoRow(
                    systemIcon: "lock.shield",
                    text: "照片只在本机读取和排版，不会上传到云端。"
                )
            }
        }
    }

    private func photoPickerButton(title: String) -> some View {
        PhotosPicker(
            selection: $photoItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(AuroraFont.labelLarge)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: AuroraMetrics.primaryButtonHeight)
            .foregroundStyle(Aurora.onBrandContainer)
            .background(AuroraShape.button.fill(Aurora.brandContainer))
        }
        .buttonStyle(.plain)
    }

    private var settingsCard: some View {
        SectionCard {
            Text("打印设置")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 12) {
                MenuField(
                    title: "格式",
                    selection: formatBinding,
                    options: config.proto.supportedFormats,
                    label: { $0.label },
                    hint: config.format.hint
                )

                if config.format == .bridge {
                    InfoRow(
                        systemIcon: "desktopcomputer",
                        text: "电脑桥接会调用电脑上安装的打印机；请确认电脑端桥接程序已启动，并填那台电脑的 IP。"
                    )
                }

                if config.format.isReceipt {
                    HStack {
                        Text("纸张")
                            .font(AuroraFont.labelMedium)
                            .foregroundStyle(Aurora.inkSoft)
                        Spacer()
                        Text(config.format == .esc80 ? "80mm 连续纸（576 点）" : "58mm 连续纸（384 点）")
                            .font(AuroraFont.bodySmall)
                            .foregroundStyle(Aurora.ink)
                    }
                } else {
                    MenuField(
                        title: "纸张",
                        selection: Binding(get: { options.paper }, set: { options.paper = $0 }),
                        options: PaperSize.allCases.filter { !$0.isReceipt },
                        label: { $0.label }
                    )

                    if options.paper == .custom {
                        HStack(spacing: 10) {
                            LabeledField(title: "宽（mm）") {
                                AuroraTextField(
                                    placeholder: "100",
                                    text: $widthText,
                                    systemIcon: "arrow.left.and.right",
                                    keyboardType: .decimalPad
                                )
                            }
                            LabeledField(title: "高（mm）") {
                                AuroraTextField(
                                    placeholder: "150",
                                    text: $heightText,
                                    systemIcon: "arrow.up.and.down",
                                    keyboardType: .decimalPad
                                )
                            }
                        }
                    }
                }

                Divider()
                    .background(Aurora.hairline)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("份数")
                            .font(AuroraFont.labelMedium)
                            .foregroundStyle(Aurora.inkSoft)
                        Text(config.format == .bridge ? "电脑桥接最多 20 份" : "最多 99 份")
                            .font(AuroraFont.labelSmall)
                            .foregroundStyle(Aurora.muted)
                    }
                    Spacer()
                    CountStepper(value: $options.copies)
                }
            }
        }
    }

    private var progressCard: some View {
        SectionCard {
            HStack {
                Text(runner.stage.isEmpty ? "打印进度" : runner.stage)
                    .font(AuroraFont.titleSmall)
                    .foregroundStyle(Aurora.ink)
                Spacer()
                Text("\(Int((runner.progress * 100).rounded()))%")
                    .font(AuroraFont.labelMedium)
                    .foregroundStyle(runner.errorText == nil ? Aurora.brand : Aurora.danger)
            }

            ProgressView(value: runner.progress)
                .tint(runner.errorText == nil ? Aurora.brand : Aurora.danger)
                .padding(.top, 10)

            if let success = runner.successText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Aurora.success)
                    Text(success)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.success)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
            }

            if let error = runner.errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Aurora.danger)
                    Text(error)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
            }

            if !runner.logs.isEmpty {
                Divider()
                    .background(Aurora.hairline)
                    .padding(.vertical, 10)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(runner.logs.suffix(10))) { entry in
                        logRow(entry)
                    }
                }
            }
        }
    }

    private func logRow(_ entry: PrintLogEntry) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(logColor(entry.level))
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            Text(entry.timeText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Aurora.muted)
            Text(entry.text)
                .font(AuroraFont.bodySmall)
                .foregroundStyle(entry.level == .error ? Aurora.danger : Aurora.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func messageCard(_ text: String, ok: Bool) -> some View {
        SectionCard {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ok ? Aurora.success : Aurora.danger)
                Text(text)
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(ok ? Aurora.success : Aurora.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        GlassBar {
            HStack(spacing: 10) {
                TonalButton(text: runner.isRunning ? "后台" : "关闭", systemIcon: runner.isRunning ? "arrow.down.right" : "xmark") {
                    dismiss()
                }
                GradientButton(
                    text: runner.isRunning ? "正在打印…" : "开始打印",
                    systemIcon: "printer.fill",
                    enabled: currentSource != nil && !runner.isRunning
                ) {
                    startPrint()
                }
            }
        }
        .padding(.horizontal, AuroraMetrics.pagePadding)
        .padding(.bottom, 10)
    }

    // MARK: - 绑定

    private var formatBinding: Binding<PrintFormat> {
        Binding(
            get: { config.format },
            set: { newValue in
                config.format = newValue
                if newValue == .bridge {
                    config.proto = .raw
                    config.port = 9100
                }
                if !newValue.isReceipt && options.paper.isReceipt {
                    options.paper = .a4
                }
                config.normalizeFormat()
                store.update(config)
            }
        )
    }

    // MARK: - 动作

    private var currentSource: PrintSource? {
        switch tab {
        case .test:
            return .test
        case .file:
            return selectedFile.map { .file($0) }
        case .photo:
            return photoURL.map { .file($0) }
        case .web:
            let trimmed = webURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .web(trimmed)
        }
    }

    private func startPrint() {
        guard let source = currentSource else { return }

        config.paper = options.paper
        config.customWidthMM = options.customWidthMM
        config.customHeightMM = options.customHeightMM
        store.update(config)

        runner.start(printer: config, source: source, options: options) {
            store.markPrint(id: config.id)
        }
    }

    private func runTest() {
        guard !testing else { return }
        testing = true
        testDetail = nil
        let snapshot = config

        Task { @MainActor in
            let result = await PrintTransport.test(snapshot)
            testing = false
            testOK = result.ok
            var detail = result.detail

            if result.detail.contains("探测到电脑桥接") && config.format != .bridge {
                config.format = .bridge
                config.proto = .raw
                config.port = 9100
                store.update(config)
                detail = "检测到电脑桥接，已自动切换为「电脑桥接直传」。"
            }

            testDetail = detail
            store.markTest(id: config.id, ok: result.ok, detail: detail)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }

        Task { @MainActor in
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PrintSourceError.badImage
                }
                guard let image = UIImage(data: data) else {
                    throw PrintSourceError.badImage
                }

                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lanprint-photo-\(UUID().uuidString).\(ext)")
                try data.write(to: destination, options: .atomic)

                let oldURL = photoURL
                photoURL = destination
                photoPreview = image
                let pixelWidth = Int(image.size.width * image.scale)
                let pixelHeight = Int(image.size.height * image.scale)
                photoInfo = "\(pixelWidth) × \(pixelHeight) · \(Format.bytes(data.count))"
                fileError = nil

                if let oldURL, oldURL != destination {
                    try? FileManager.default.removeItem(at: oldURL)
                }
            } catch {
                photoItem = nil
                fileError = "读取相册图片失败：\(error.localizedDescription)"
            }
        }
    }

    private func clearPhoto() {
        if let photoURL {
            try? FileManager.default.removeItem(at: photoURL)
        }
        photoURL = nil
        photoPreview = nil
        photoInfo = ""
        photoItem = nil
        fileError = nil
    }

    private func importFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("lanprint-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)

            selectedFile = destination
            fileError = nil
            if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
               let size = attributes[.size] as? NSNumber {
                fileSizeText = Format.bytes(size.intValue)
            } else {
                fileSizeText = ""
            }
        } catch {
            fileError = "读取文件失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 小工具

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.pdf, .image, .plainText, .commaSeparatedText, .json, .html]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        return types
    }

    private var paperLabel: String {
        if config.format == .esc58 { return "58mm" }
        if config.format == .esc80 { return "80mm" }
        return options.paper.shortLabel
    }

    private func kindLabel(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return "PDF 文档" }
        if ["png", "jpg", "jpeg", "heic", "gif", "bmp", "tiff", "webp"].contains(ext) {
            return "图片"
        }
        if ["html", "htm"].contains(ext) { return "网页文件" }
        return "文本文件"
    }

    private func fileIcon(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return "doc.richtext" }
        if ["png", "jpg", "jpeg", "heic", "gif", "bmp", "tiff", "webp"].contains(ext) {
            return "photo"
        }
        if ["html", "htm"].contains(ext) { return "globe" }
        return "doc.text"
    }

    private func logColor(_ level: PrintLogEntry.Level) -> Color {
        switch level {
        case .info: return Aurora.brand
        case .success: return Aurora.success
        case .warning: return Aurora.warning
        case .error: return Aurora.danger
        }
    }

    // MARK: - 内容来源

    private enum SourceTab: String, CaseIterable, Hashable {
        case test
        case file
        case photo
        case web

        var label: String {
            switch self {
            case .test: return "测试页"
            case .file: return "文件"
            case .photo: return "图片"
            case .web: return "网页"
            }
        }
    }
}
