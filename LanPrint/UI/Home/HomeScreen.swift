import SwiftUI

struct HomeScreen: View {

    @EnvironmentObject private var store: PrinterStore

    @State private var editor: EditorMode?
    @State private var showScan = false
    @State private var printing: PrinterConfig?
    @State private var deleteTarget: PrinterConfig?
    @State private var testingID: UUID?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            AuroraBackdrop()

            VStack(spacing: 0) {
                topBar
                content
            }

            bottomBar
        }
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showScan) {
            ScanScreen(
                onPick: { result in pickScan(result) },
                onManualAdd: {
                    showScan = false
                    openEditorAfterScan(EditorMode.add(nil))
                }
            )
        }
        .sheet(item: $editor) { mode in
            AddPrinterScreen(original: mode.original, isNew: !mode.isEdit) { saved in
                if mode.isEdit {
                    store.update(saved)
                    showToast("已保存修改")
                } else {
                    store.add(saved)
                    showToast("已添加 \(saved.displayName)")
                }
            }
        }
        .fullScreenCover(item: $printing) { printer in
            PrintScreen(printer: printer)
                .environmentObject(store)
        }
        .confirmationDialog(
            "删除打印机？",
            isPresented: deleteBinding,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { printer in
            Button("删除 \(printer.displayName)", role: .destructive) {
                store.delete(id: printer.id)
                deleteTarget = nil
                showToast("已删除 \(printer.displayName)")
            }
            Button("取消", role: .cancel) {
                deleteTarget = nil
            }
        } message: { _ in
            Text("只删除本机保存的配置，不会影响打印机本身。")
        }
        .animation(.easeOut(duration: 0.2), value: toast)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        AppTopBar(title: "局域网打印", subtitle: subtitle) {
            Button {
                showScan = true
            } label: {
                Image(systemName: "wifi.router")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Aurora.ink)
                    .frame(width: AuroraMetrics.iconButtonSize, height: AuroraMetrics.iconButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var subtitle: String {
        if store.printers.isEmpty {
            return "同一 Wi-Fi 下打印文件、网页和小票"
        }
        return "已保存 \(store.printers.count) 台打印机 · 点卡片开始打印"
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                if store.printers.isEmpty {
                    emptyCard
                } else {
                    ForEach(store.printers) { printer in
                        printerCard(printer)
                    }
                }
                tipsCard
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, AuroraMetrics.listBottomInset)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyCard: some View {
        SectionCard {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Aurora.brand.tint(0.10))
                    .frame(width: 84, height: 84)
                    .overlay(
                        Image(systemName: "printer.fill")
                            .font(.system(size: 37, weight: .regular))
                            .foregroundStyle(Aurora.brand)
                    )

                Text("还没有添加打印机")
                    .font(AuroraFont.titleLarge)
                    .foregroundStyle(Aurora.ink)

                Text("同一 Wi-Fi 下点「扫描」自动发现，\n或点「添加打印机」手动填写 IP。")
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.inkSoft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    private var tipsCard: some View {
        SectionCard {
            Text("连接提示")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 9) {
                InfoRow(systemIcon: "wifi", text: "手机和打印机要连在同一个 Wi-Fi / 局域网。")
                InfoRow(systemIcon: "number", text: "不知道 IP？用「扫描」自动发现，或在打印机面板打印网络配置页。")
                InfoRow(systemIcon: "hand.tap", text: "长按打印机卡片，可编辑、测试连接或删除。")
                InfoRow(systemIcon: "doc.text", text: "支持 PDF、图片、txt / md、网页和内置测试页。")
            }
        }
    }

    // MARK: - 打印机卡片

    private func printerCard(_ printer: PrinterConfig) -> some View {
        let isTesting = testingID == printer.id
        let tone = protocolTone(printer.proto)

        return SectionCard {
            HStack(alignment: .top, spacing: 12) {
                Monogram(name: printer.displayName, tone: tone)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(printer.displayName)
                            .font(AuroraFont.titleMedium)
                            .foregroundStyle(Aurora.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        cardMenu(printer)
                    }

                    Text(printer.endpoint)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: printer.connectionIcon)
                            .font(.system(size: 10, weight: .semibold))
                        Text("连接方式：\(printer.connectionLabel)")
                            .font(AuroraFont.labelSmall)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Aurora.muted)

                    HStack(spacing: 6) {
                        StatusPill(text: printer.proto.shortLabel, color: Aurora.brand)
                        StatusPill(
                            text: printer.format.shortLabel,
                            color: printer.format == .bridge ? Aurora.rose : Aurora.teal
                        )
                        StatusPill(text: paperLabel(printer), color: Aurora.muted)
                    }
                    .padding(.top, 1)

                    if isTesting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("测试中…")
                                .font(AuroraFont.labelSmall)
                                .foregroundStyle(Aurora.inkSoft)
                        }
                        .padding(.top, 2)
                    } else if let detail = printer.lastTestDetail, !detail.isEmpty {
                        Text(detail)
                            .font(AuroraFont.labelSmall)
                            .foregroundStyle(printer.lastTestOK == true ? Aurora.success : Aurora.muted)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .contentShape(AuroraShape.card)
        .onTapGesture {
            printing = printer
        }
        .contextMenu {
            Button {
                editor = .edit(printer)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button {
                test(printer)
            } label: {
                Label("测试连接", systemImage: "bolt.horizontal")
            }
            Button {
                printing = printer
            } label: {
                Label("打印", systemImage: "printer")
            }
            Divider()
            Button(role: .destructive) {
                deleteTarget = printer
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func cardMenu(_ printer: PrinterConfig) -> some View {
        Menu {
            Button {
                printing = printer
            } label: {
                Label("打印", systemImage: "printer")
            }
            Button {
                editor = .edit(printer)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button {
                test(printer)
            } label: {
                Label("测试连接", systemImage: "bolt.horizontal")
            }
            Divider()
            Button(role: .destructive) {
                deleteTarget = printer
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Aurora.muted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部操作条

    private var bottomBar: some View {
        GlassBar {
            HStack(spacing: 10) {
                TonalButton(text: "扫描", systemIcon: "wifi.router") {
                    showScan = true
                }
                PrimaryButton(text: "添加打印机", systemIcon: "plus") {
                    editor = .add(nil)
                }
            }
        }
        .padding(.horizontal, AuroraMetrics.pagePadding)
        .padding(.bottom, 10)
    }

    // MARK: - 提示条

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(AuroraFont.labelMedium)
                .foregroundStyle(Aurora.onBrandContainer)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Aurora.brandContainer)
                        .shadow(color: Aurora.cardShadow, radius: 6, x: 0, y: 2)
                )
                .padding(.top, 68)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { self.toast = nil }
        }
    }

    // MARK: - 动作

    private func test(_ printer: PrinterConfig) {
        guard testingID == nil else { return }
        testingID = printer.id
        showToast("正在测试 \(printer.displayName)…")

        Task { @MainActor in
            let result = await PrintTransport.test(printer)
            var detail = result.detail

            if result.detail.contains("探测到电脑桥接") && printer.format != .bridge {
                var updated = printer
                updated.format = .bridge
                updated.proto = .raw
                updated.port = 9100
                store.update(updated)
                detail = "检测到电脑桥接，已自动切换为「电脑桥接直传」。"
            }

            store.markTest(id: printer.id, ok: result.ok, detail: detail)
            testingID = nil
            showToast(detail)
        }
    }

    private func pickScan(_ result: ScanResult) {
        showScan = false
        var printer = PrinterConfig.make(protocol: result.proto, host: result.host)
        printer.port = result.port
        printer.format = result.format
        printer.normalizeFormat()
        openEditorAfterScan(.add(printer))
    }

    private func openEditorAfterScan(_ mode: EditorMode) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            editor = mode
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: - 小工具

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private func protocolTone(_ proto: PrinterProtocol) -> Color {
        switch proto {
        case .raw: return Aurora.brand
        case .lpr: return Aurora.teal
        case .ipp: return Aurora.rose
        }
    }

    private func paperLabel(_ printer: PrinterConfig) -> String {
        if printer.format == .esc58 { return "58mm" }
        if printer.format == .esc80 { return "80mm" }
        return printer.paper.shortLabel
    }

    // MARK: - 编辑模式

    private enum EditorMode: Identifiable {
        case add(PrinterConfig?)
        case edit(PrinterConfig)

        var id: String {
            switch self {
            case .add(let printer):
                return "add-\(printer?.id.uuidString ?? "new")"
            case .edit(let printer):
                return "edit-\(printer.id.uuidString)"
            }
        }

        var original: PrinterConfig? {
            switch self {
            case .add(let printer): return printer
            case .edit(let printer): return printer
            }
        }

        var isEdit: Bool {
            if case .edit = self { return true }
            return false
        }
    }
}
