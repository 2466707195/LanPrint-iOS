import SwiftUI

struct AddPrinterScreen: View {

    private let original: PrinterConfig?
    private let isNew: Bool
    private let onSave: (PrinterConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: PrinterConfig
    @State private var portText: String
    @State private var widthText: String
    @State private var heightText: String
    @State private var testing = false
    @State private var testResult: (ok: Bool, detail: String)?
    @State private var validationMessage: String?

    init(original: PrinterConfig?, isNew: Bool, onSave: @escaping (PrinterConfig) -> Void) {
        self.original = original
        self.isNew = isNew
        self.onSave = onSave

        let initial = original ?? PrinterConfig.make(protocol: .raw, host: "")
        _draft = State(initialValue: initial)
        _portText = State(initialValue: String(initial.port))
        _widthText = State(initialValue: String(format: "%.0f", initial.customWidthMM))
        _heightText = State(initialValue: String(format: "%.0f", initial.customHeightMM))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AuroraBackdrop()

            VStack(spacing: 0) {
                AppTopBar(
                    title: isNew ? "添加打印机" : "编辑打印机",
                    subtitle: "填写 IP、协议和输出格式",
                    onBack: { dismiss() }
                )
                content
            }

            bottomBar
        }
        .animation(.easeOut(duration: 0.2), value: validationMessage)
        .animation(.easeOut(duration: 0.2), value: testResult?.ok)
        .onChange(of: portText) { value in
            if let port = Int(value) {
                draft.port = port
            }
        }
        .onChange(of: widthText) { value in
            if let width = Double(value) {
                draft.customWidthMM = width
            }
        }
        .onChange(of: heightText) { value in
            if let height = Double(value) {
                draft.customHeightMM = height
            }
        }
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                networkCard
                outputCard
                testCard
                if let validationMessage {
                    messageCard(validationMessage, ok: false)
                }
                tipsCard
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, AuroraMetrics.listBottomInset)
        }
        .scrollIndicators(.hidden)
    }

    private var networkCard: some View {
        SectionCard {
            Text("网络")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 12) {
                LabeledField(title: "名称") {
                    AuroraTextField(
                        placeholder: "例如：办公室打印机",
                        text: $draft.name,
                        systemIcon: "printer"
                    )
                }

                LabeledField(
                    title: "地址 / 主机名",
                    hint: "可填 192.168.1.20 或 printer.local；电脑桥接填那台电脑的 IP。"
                ) {
                    AuroraTextField(
                        placeholder: "192.168.1.20",
                        text: $draft.host,
                        systemIcon: "network"
                    )
                }

                LabeledField(
                    title: "端口",
                    hint: draft.format == .bridge ? "电脑桥接固定使用 9100。" : nil
                ) {
                    AuroraTextField(
                        placeholder: "9100",
                        text: $portText,
                        systemIcon: "number",
                        keyboardType: .numberPad
                    )
                }

                MenuField(
                    title: "协议",
                    selection: protocolBinding,
                    options: PrinterProtocol.allCases,
                    label: { $0.label },
                    hint: draft.proto.hint
                )

                if draft.format == .bridge {
                    InfoRow(
                        systemIcon: "desktopcomputer",
                        text: "电脑桥接：先在电脑上运行桥接程序，这里填电脑 IP，端口 9100。手机和电脑要在同一局域网。"
                    )
                }
            }
        }
    }

    private var outputCard: some View {
        SectionCard {
            Text("输出")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 12) {
                MenuField(
                    title: "打印机语言 / 指令集",
                    selection: formatBinding,
                    options: draft.proto.supportedFormats,
                    label: { $0.label },
                    hint: draft.format.hint
                )

                if draft.format == .bridge {
                    InfoRow(
                        systemIcon: "checkmark.seal",
                        text: "电脑桥接支持 A5 / 自定义纸张；电脑端桥接程序负责调用 Windows 里安装的打印机。"
                    )
                }

                if !draft.format.isReceipt {
                    MenuField(
                        title: "纸张",
                        selection: Binding(get: { draft.paper }, set: { draft.paper = $0 }),
                        options: PaperSize.allCases.filter { !$0.isReceipt },
                        label: { $0.label }
                    )

                    if draft.paper == .custom {
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

                        InfoRow(
                            systemIcon: "info.circle",
                            text: "自定义纸张按实际尺寸排版；PCL 打印机不能指定物理纸盒，请把同尺寸纸放进纸盒。"
                        )
                    }
                } else {
                    InfoRow(
                        systemIcon: "scissors",
                        text: "小票格式按 \(draft.format == .esc80 ? "80mm / 576 点" : "58mm / 384 点")宽输出，纸张设置自动忽略。"
                    )
                }

                if draft.proto == .lpr {
                    LabeledField(title: "LPR 队列名", hint: "大多数打印机填 lp。") {
                        AuroraTextField(
                            placeholder: "lp",
                            text: $draft.queue,
                            systemIcon: "tray.full"
                        )
                    }
                }

                if draft.proto == .ipp {
                    LabeledField(title: "IPP 路径", hint: "常见为 /ipp/print，可按打印机说明书调整。") {
                        AuroraTextField(
                            placeholder: "/ipp/print",
                            text: $draft.ippPath,
                            systemIcon: "link"
                        )
                    }
                }
            }
        }
    }

    private var testCard: some View {
        SectionCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("测试连接")
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.ink)
                    Text("只检测端口是否可连接，不会打印内容。")
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                }
                Spacer(minLength: 6)
                SmallTonalButton(
                    text: testing ? "测试中…" : "测试",
                    systemIcon: "bolt.horizontal",
                    enabled: !testing
                ) {
                    runTest()
                }
            }

            if let testResult {
                Divider()
                    .background(Aurora.hairline)
                    .padding(.vertical, 10)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(testResult.ok ? Aurora.success : Aurora.danger)
                    Text(testResult.detail)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(testResult.ok ? Aurora.success : Aurora.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var tipsCard: some View {
        SectionCard {
            Text("怎么填")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 9) {
                InfoRow(systemIcon: "printer", text: "IP 可以在打印机的网络配置页找到，或先在主页用「扫描」自动发现。")
                InfoRow(systemIcon: "bolt.horizontal", text: "旧打印机优先选 RAW 9100 + 光栅 PCL；热敏小票机选对应 58 / 80mm。")
                InfoRow(systemIcon: "lock.shield", text: "所有内容都在本机生成，只发送到这台打印机，不经过云端。")
            }
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
                TonalButton(
                    text: testing ? "测试中…" : "测试连接",
                    systemIcon: "bolt.horizontal",
                    enabled: !testing
                ) {
                    runTest()
                }
                PrimaryButton(text: "保存", systemIcon: "checkmark") {
                    save()
                }
            }
        }
        .padding(.horizontal, AuroraMetrics.pagePadding)
        .padding(.bottom, 10)
    }

    // MARK: - 绑定

    private var protocolBinding: Binding<PrinterProtocol> {
        Binding(
            get: { draft.proto },
            set: { newValue in
                // 电脑桥接只适用于 RAW；切到 LPR / IPP 时先退回 PCL。
                if newValue != .raw && draft.format == .bridge {
                    draft.format = .pcl
                }
                let oldDefault = draft.proto.defaultPort
                draft.proto = newValue
                if draft.port == oldDefault || draft.port == 0 {
                    draft.port = newValue.defaultPort
                    portText = String(newValue.defaultPort)
                }
                draft.normalizeFormat()
            }
        )
    }

    private var formatBinding: Binding<PrintFormat> {
        Binding(
            get: { draft.format },
            set: { newValue in
                draft.format = newValue
                if newValue == .bridge {
                    draft.proto = .raw
                    draft.port = 9100
                    portText = "9100"
                }
                if !newValue.isReceipt && draft.paper.isReceipt {
                    draft.paper = .a4
                }
                draft.normalizeFormat()
            }
        )
    }

    // MARK: - 动作

    private func runTest() {
        guard validate() else { return }
        testing = true
        testResult = nil
        let snapshot = cleaned()

        Task { @MainActor in
            let result = await PrintTransport.test(snapshot)
            testing = false

            if result.detail.contains("探测到电脑桥接") && draft.format != .bridge {
                draft.format = .bridge
                draft.proto = .raw
                draft.port = 9100
                portText = "9100"
                draft.normalizeFormat()
                testResult = (result.ok, "已检测到电脑桥接，并自动切换为「电脑桥接直传」。")
            } else {
                testResult = result
            }
        }
    }

    private func save() {
        guard validate() else { return }
        var printer = cleaned()
        if printer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            printer.name = printer.host
        }
        onSave(printer)
        dismiss()
    }

    private func cleaned() -> PrinterConfig {
        var printer = draft
        printer.host = printer.host.trimmingCharacters(in: .whitespacesAndNewlines)
        printer.host = printer.host
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")

        let (host, port) = HostPort.split(printer.host)
        printer.host = host
        if let port {
            printer.port = port
        }
        if printer.port == 0 {
            printer.port = printer.proto.defaultPort
        }
        printer.customWidthMM = Double(widthText) ?? printer.customWidthMM
        printer.customHeightMM = Double(heightText) ?? printer.customHeightMM
        printer.name = printer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        printer.queue = printer.queue.trimmingCharacters(in: .whitespacesAndNewlines)
        printer.ippPath = printer.ippPath.trimmingCharacters(in: .whitespacesAndNewlines)
        printer.normalizeFormat()
        return printer
    }

    private func validate() -> Bool {
        let printer = cleaned()

        guard HostPort.isValidHost(printer.host) else {
            validationMessage = "请填写正确的打印机地址（例如 192.168.1.20）。"
            return false
        }
        guard printer.port >= 1 && printer.port <= 65535 else {
            validationMessage = "端口需要是 1 – 65535 之间的数字。"
            return false
        }
        if printer.paper == .custom && !printer.format.isReceipt {
            guard printer.customWidthMM >= 20 && printer.customWidthMM <= 500,
                  printer.customHeightMM >= 20 && printer.customHeightMM <= 1000 else {
                validationMessage = "自定义纸张宽 20 – 500 mm，高 20 – 1000 mm。"
                return false
            }
        }
        validationMessage = nil
        return true
    }
}
