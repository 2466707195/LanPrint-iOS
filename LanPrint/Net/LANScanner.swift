import Foundation
import Combine

/// 局域网扫描：对网段内 .1 ~ .254 同时探测 9100 / 515 / 631 三个打印端口。
@MainActor
final class LANScanner: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case finished
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var scannedHosts: Int = 0
    @Published private(set) var results: [ScanResult] = []
    @Published private(set) var message: String = ""
    @Published private(set) var errorText: String?

    let totalHosts = 254

    private var task: Task<Void, Never>?

    var isScanning: Bool { phase == .scanning }

    var defaultPrefix: String {
        if let ip = NetworkInfo.localIPv4() {
            return NetworkInfo.subnetPrefix(from: ip)
        }
        return "192.168.1."
    }

    // MARK: - 开始 / 取消

    func start(prefix raw: String) {
        guard !isScanning else { return }

        guard let prefix = Self.normalizePrefix(raw) else {
            errorText = "网段格式不正确，请填写类似 192.168.3. 的前缀"
            return
        }

        errorText = nil
        results = []
        scannedHosts = 0
        progress = 0
        phase = .scanning
        message = "正在扫描 \(prefix)1 – 254…"

        task = Task { [weak self] in
            await self?.run(prefix: prefix)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .scanning {
            phase = .finished
            message = "已停止扫描，已发现 \(results.count) 个打印服务。"
        }
    }

    // MARK: - 扫描实现

    private func run(prefix: String) async {
        let hosts = (1...totalHosts).map { "\(prefix)\($0)" }
        let batchSize = 16
        var index = 0
        var seen = Set<String>()

        while index < hosts.count {
            if Task.isCancelled { break }

            let end = min(index + batchSize, hosts.count)
            let batch = Array(hosts[index..<end])

            let found = await withTaskGroup(of: [ScanResult].self, returning: [ScanResult].self) { group in
                for host in batch {
                    group.addTask {
                        // 9100 顺便识别电脑桥接：桥接程序会在连接后主动发一行握手。
                        async let rawProbe = SocketClient.probeBridge(
                            host: host,
                            port: 9100,
                            connectTimeout: 0.7,
                            greetingTimeout: 0.8
                        )
                        async let lpr = SocketClient.probe(host: host, port: 515)
                        async let ipp = SocketClient.probe(host: host, port: 631)

                        let raw = await rawProbe
                        let (hasLpr, hasIpp) = await (lpr, ipp)
                        let hasRaw = raw.connected
                        let greeting = raw.greeting ?? ""
                        let isBridge = greeting.hasPrefix("LPBRIDGE1") || greeting.hasPrefix("LPBRIDGE2")
                        var out: [ScanResult] = []
                        if hasRaw {
                            out.append(
                                ScanResult(
                                    host: host,
                                    port: 9100,
                                    proto: .raw,
                                    format: isBridge ? .bridge : .pcl,
                                    detail: isBridge ? "9100 电脑桥接服务" : "9100 端口开放（RAW）"
                                )
                            )
                        }
                        if hasLpr {
                            out.append(ScanResult(host: host, port: 515, proto: .lpr, detail: "515 端口开放（LPR）"))
                        }
                        if hasIpp {
                            out.append(ScanResult(host: host, port: 631, proto: .ipp, detail: "631 端口开放（IPP）"))
                        }
                        return out
                    }
                }

                var all: [ScanResult] = []
                for await item in group {
                    all.append(contentsOf: item)
                }
                return all
            }

            for item in found where !seen.contains(item.id) {
                seen.insert(item.id)
                results.append(item)
            }

            index = end
            scannedHosts = min(index, totalHosts)
            progress = Double(scannedHosts) / Double(totalHosts)
            sortResults()

            if Task.isCancelled { break }
        }

        if Task.isCancelled { return }

        scannedHosts = totalHosts
        progress = 1
        phase = .finished
        if results.isEmpty {
            message = "本网段没有发现打印服务。请确认打印机与手机在同一 Wi-Fi，或手动添加 IP。"
        } else {
            message = "发现 \(results.count) 个打印服务，点任意一行直接添加。"
        }
    }

    private func sortResults() {
        results.sort { lhs, rhs in
            if lhs.host == rhs.host { return lhs.port < rhs.port }
            return Self.hostOrder(lhs.host) < Self.hostOrder(rhs.host)
        }
    }

    // MARK: - 工具

    private static func hostOrder(_ host: String) -> Int {
        host.split(separator: ".").last.flatMap { Int($0) } ?? 0
    }

    /// 接受 "192.168.3."、"192.168.3"、"192.168.3.25"，统一成 "192.168.3."。
    static func normalizePrefix(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        // 去掉常见协议 / 路径残留
        text = text.replacingOccurrences(of: "http://", with: "")
        text = text.replacingOccurrences(of: "https://", with: "")
        while text.hasSuffix(".") {
            // 保留最后一个点，由下面统一补齐
            text.removeLast()
        }

        let parts = text.split(separator: ".")
        guard parts.count == 3 || parts.count == 4 else { return nil }

        let octets = parts.prefix(3).compactMap { Int($0) }
        guard octets.count == 3, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return nil }

        return "\(octets[0]).\(octets[1]).\(octets[2])."
    }
}
