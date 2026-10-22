import Foundation
import Combine

/// 一次打印任务的执行器：生成数据 → 发送 → 记录日志。
@MainActor
final class PrintJobRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var stage: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var logs: [PrintLogEntry] = []
    @Published private(set) var errorText: String?
    @Published private(set) var successText: String?
    @Published private(set) var finished = false

    private var task: Task<Void, Never>?
    private var startedAt: Date?

    func start(
        printer: PrinterConfig,
        source: PrintSource,
        options: PrintOptions,
        onSuccess: @escaping () -> Void
    ) {
        guard !isRunning else { return }

        isRunning = true
        finished = false
        stage = "准备打印"
        progress = 0
        logs = []
        errorText = nil
        successText = nil
        startedAt = Date()

        append("开始打印：\(source.kindLabel) → \(printer.displayName)", level: .info)

        let logClosure: (PrintLogEntry.Level, String) -> Void = { [weak self] level, text in
            Task { @MainActor in
                self?.append(text, level: level)
            }
        }

        let progressClosure: (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                self.progress = max(self.progress, min(1, value))
            }
        }

        task = Task { [weak self] in
            guard let self else { return }

            do {
                self.stage = "生成打印数据"
                let payload = try await PrintPipeline.buildPayload(
                    printer: printer,
                    source: source,
                    options: options,
                    log: logClosure,
                    progress: progressClosure
                )

                try Task.checkCancellation()
                self.progress = max(self.progress, 0.55)
                self.append("打印数据已生成：\(Format.bytes(payload.count))", level: .success)

                self.stage = "发送到打印机"
                try await PrintTransport.send(
                    printer: printer,
                    payload: payload,
                    jobName: Self.jobName(source: source),
                    copies: options.clampedCopies,
                    log: logClosure
                ) { value in
                    progressClosure(0.55 + 0.45 * value)
                }

                try Task.checkCancellation()
                self.progress = 1
                self.stage = "打印完成"
                self.successText = "已发送到 \(printer.displayName)（\(printer.endpoint)）"
                self.append("打印任务完成。", level: .success)
                self.isRunning = false
                self.finished = true
                onSuccess()

            } catch is CancellationError {
                self.stage = "已取消"
                self.append("已取消打印。", level: .warning)
                self.isRunning = false
                self.finished = true

            } catch {
                let message = error.localizedDescription
                self.errorText = message
                self.stage = "打印失败"
                self.append(message, level: .error)
                self.append(Self.suggestion(for: error), level: .info)
                self.isRunning = false
                self.finished = true
            }
        }
    }

    func reset() {
        guard !isRunning else { return }
        stage = ""
        progress = 0
        logs = []
        errorText = nil
        successText = nil
        finished = false
    }

    private func append(_ text: String, level: PrintLogEntry.Level) {
        logs.append(PrintLogEntry(text, level: level))
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    private static func jobName(source: PrintSource) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "LanPrint \(source.kindLabel) \(formatter.string(from: Date()))"
    }

    private static func suggestion(for error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("超时") || text.contains("拒绝") || text.contains("不可达") {
            return "检查打印机是否开机、有纸、未脱机；网线和 Wi-Fi 是否正常。"
        }
        if text.contains("文档格式") || text.contains("不支持该文档") {
            return "打印机可能不支持当前格式，试试把格式改成「光栅 PCL」。"
        }
        if text.contains("LPD") || text.contains("队列") {
            return "检查 LPR 队列名（一般为 lp）是否正确。"
        }
        if text.contains("IPP") || text.contains("HTTP") {
            return "确认打印机开启了 IPP / AirPrint，端口为 631。"
        }
        return "确认地址、端口和协议与打印机一致，可先用「测试连接」检查。"
    }
}
