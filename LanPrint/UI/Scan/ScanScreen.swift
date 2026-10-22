import SwiftUI

struct ScanScreen: View {

    let onPick: (ScanResult) -> Void
    let onManualAdd: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = LANScanner()
    @State private var prefix = ""
    @State private var started = false

    var body: some View {
        ZStack(alignment: .bottom) {
            AuroraBackdrop()

            VStack(spacing: 0) {
                AppTopBar(
                    title: "扫描打印机",
                    subtitle: "探测 .1 – .254 的 9100 / 515 / 631 端口",
                    onBack: {
                        scanner.cancel()
                        dismiss()
                    }
                )
                content
            }

            bottomBar
        }
        .onAppear {
            let initial = prefix.isEmpty ? scanner.defaultPrefix : prefix
            if prefix.isEmpty {
                prefix = initial
            }
            if !started {
                started = true
                scanner.start(prefix: initial)
            }
        }
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                subnetCard
                resultsCard
                tipsCard
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, AuroraMetrics.listBottomInset)
        }
        .scrollIndicators(.hidden)
    }

    private var subnetCard: some View {
        SectionCard {
            Text("网段")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
                .padding(.bottom, 12)

            LabeledField(title: "网段前缀", hint: "只扫描前缀下的 .1 – .254，例如 192.168.3.") {
                AuroraTextField(
                    placeholder: "192.168.3.",
                    text: $prefix,
                    systemIcon: "wifi",
                    keyboardType: .numbersAndPunctuation
                )
            }

            if let error = scanner.errorText, !error.isEmpty {
                Text(error)
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.danger)
                    .padding(.top, 8)
            }

            if scanner.isScanning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: scanner.progress)
                        .tint(Aurora.brand)
                    HStack {
                        Text("已扫描 \(scanner.scannedHosts) / \(scanner.totalHosts)")
                            .font(AuroraFont.labelSmall)
                            .foregroundStyle(Aurora.inkSoft)
                        Spacer()
                        Text("发现 \(scanner.results.count) 个")
                            .font(AuroraFont.labelSmall)
                            .foregroundStyle(Aurora.brand)
                    }
                }
                .padding(.top, 12)

                SmallTonalButton(text: "停止扫描", systemIcon: "stop.fill") {
                    scanner.cancel()
                }
                .padding(.top, 10)
            } else {
                PrimaryButton(
                    text: scanner.phase == .finished ? "重新扫描" : "开始扫描",
                    systemIcon: "radar"
                ) {
                    scanner.start(prefix: prefix)
                }
                .padding(.top, 12)
            }

            if !scanner.message.isEmpty {
                Text(scanner.message)
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    private var resultsCard: some View {
        SectionCard {
            HStack {
                Text("扫描结果")
                    .font(AuroraFont.titleSmall)
                    .foregroundStyle(Aurora.ink)
                Spacer()
                Text("\(scanner.results.count)")
                    .font(AuroraFont.labelMedium)
                    .foregroundStyle(Aurora.brand)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Aurora.brandContainer))
            }
            .padding(.bottom, scanner.results.isEmpty ? 12 : 6)

            if scanner.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: scanner.isScanning ? "radar" : "wifi.slash")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Aurora.brand)
                        .frame(width: 64, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Aurora.brand.tint(0.10))
                        )
                    Text(scanner.isScanning ? "正在扫描局域网…" : "本网段暂时没有结果")
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.ink)
                    Text(scanner.isScanning
                         ? "每个地址会同时探测 9100、515、631 三个端口。"
                         : "确认打印机与手机在同一 Wi-Fi，或返回手动添加 IP。")
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(scanner.results.indices, id: \.self) { index in
                        if index > 0 {
                            Divider()
                                .background(Aurora.hairline)
                        }
                        resultRow(scanner.results[index])
                    }
                }
            }
        }
    }

    private func resultRow(_ result: ScanResult) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(resultTone(result).tint(0.13))
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: result.isBridge ? "desktopcomputer" : "printer.fill")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(resultTone(result))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(result.host)
                    .font(AuroraFont.titleMedium)
                    .foregroundStyle(Aurora.ink)
                HStack(spacing: 6) {
                    StatusPill(
                        text: result.isBridge ? "电脑桥接" : result.proto.shortLabel,
                        color: resultTone(result)
                    )
                    Text(result.isBridge ? "端口 9100 · 桥接服务" : "端口 \(result.port)")
                        .font(AuroraFont.labelSmall)
                        .foregroundStyle(Aurora.muted)
                }
            }

            Spacer(minLength: 4)

            SmallTonalButton(text: "添加", expands: false) {
                onPick(result)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var tipsCard: some View {
        SectionCard {
            Text("没有找到？")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 9) {
                InfoRow(systemIcon: "wifi.exclamationmark", text: "iOS 会先询问「本地网络」权限，必须允许，否则扫描不到任何设备。")
                InfoRow(systemIcon: "network.slash", text: "公司网络或访客 Wi-Fi 可能隔离设备，换到打印机所在的网络再试。")
                InfoRow(systemIcon: "keyboard", text: "也可以点底部「手动添加」，直接填写打印机 IP。")
            }
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        GlassBar {
            HStack(spacing: 10) {
                TonalButton(text: "手动添加", systemIcon: "keyboard") {
                    scanner.cancel()
                    onManualAdd()
                }
                PrimaryButton(
                    text: scanner.isScanning ? "扫描中…" : "重新扫描",
                    systemIcon: "arrow.clockwise",
                    enabled: !scanner.isScanning
                ) {
                    scanner.start(prefix: prefix)
                }
            }
        }
        .padding(.horizontal, AuroraMetrics.pagePadding)
        .padding(.bottom, 10)
    }

    private func resultTone(_ result: ScanResult) -> Color {
        if result.isBridge { return Aurora.rose }
        return tone(result.proto)
    }

    private func tone(_ proto: PrinterProtocol) -> Color {
        switch proto {
        case .raw: return Aurora.brand
        case .lpr: return Aurora.teal
        case .ipp: return Aurora.rose
        }
    }
}
