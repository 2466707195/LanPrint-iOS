import Foundation

// MARK: - 传输错误

enum TransportError: LocalizedError {
    case badHost
    case badURL
    case http(Int)
    case ipp(UInt16)
    case lpr(String)
    case network(String)
    case emptyPayload
    case bridgeMismatch

    var errorDescription: String? {
        switch self {
        case .badHost:
            return "打印机地址为空或格式不正确"
        case .badURL:
            return "IPP 地址无法构造（检查地址和路径）"
        case .http(let code):
            return "打印机返回 HTTP \(code)"
        case .ipp(let status):
            return Self.ippMessage(status)
        case .lpr(let text):
            return "LPD 打印失败：\(text)"
        case .network(let text):
            return text
        case .emptyPayload:
            return "没有可发送的打印数据"
        case .bridgeMismatch:
            return "这个 9100 端口是电脑桥接服务，不是直连打印机。请编辑打印机，把格式改成「电脑桥接直传」后重试。"
        }
    }

    static func ippMessage(_ status: UInt16) -> String {
        switch status {
        case 0x0000: return "打印成功"
        case 0x0401: return "打印机拒绝请求（需要认证）"
        case 0x0402: return "打印机拒绝请求（禁止访问）"
        case 0x0403: return "打印机拒绝请求（不支持该参数）"
        case 0x0405: return "打印机不支持该属性"
        case 0x0406: return "打印机不支持该文档格式"
        case 0x040A: return "打印机拒绝该文档格式"
        case 0x0500: return "打印机内部错误"
        case 0x0501: return "打印机不支持该操作"
        case 0x0502: return "打印机不支持该文档"
        case 0x0503: return "打印机忙，请稍后再试"
        case 0x0505: return "打印机当前不可用"
        case 0x0506: return "打印机返回错误"
        case 0x0507: return "打印任务已取消"
        default:
            return String(format: "打印机拒绝请求（状态 0x%04X）", status)
        }
    }
}

// MARK: - 传输层

enum PrintTransport {

    // MARK: 测试连接

    static func test(_ printer: PrinterConfig) async -> (ok: Bool, detail: String) {
        guard !printer.host.isEmpty else {
            return (false, "请先填写打印机地址")
        }

        if printer.format == .bridge && printer.port != 9100 {
            return (false, "电脑桥接必须连接电脑的 9100 端口，请把端口改成 9100。")
        }

        let start = Date()

        // 9100 端口顺带识别电脑桥接程序：它会先发一行 LPBRIDGE1 ... 握手信息。
        if printer.port == 9100 {
            let probe = await SocketClient.probeBridge(
                host: printer.host,
                port: printer.port,
                connectTimeout: 5,
                greetingTimeout: 1.2
            )
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
            guard probe.connected else {
                return (false, "无法连接 \(printer.endpoint)，请检查打印机电源、IP 和端口")
            }

            let greeting = probe.greeting ?? ""
            let isBridge = greeting.hasPrefix("LPBRIDGE1") || greeting.hasPrefix("LPBRIDGE2")

            if printer.format == .bridge {
                if isBridge {
                    let v2 = greeting.uppercased().contains("V2")
                    let suffix = v2 ? " · 支持 A5 / 自定义纸张" : " · 旧版桥接，按电脑默认纸张"
                    return (true, "电脑桥接正常 · \(ms) ms\(suffix)")
                }
                return (false, "端口通，但没有收到桥接程序的握手信息。请确认电脑上的桥接程序已启动，且连接的是那台电脑的 IP。")
            }

            if isBridge {
                return (true, "端口通（探测到电脑桥接）· \(ms) ms。当前格式不是「电脑桥接」，请编辑打印机改格式后打印。")
            }

            return (true, "连接成功 · \(printer.endpoint) · \(ms) ms")
        }

        let ok = await SocketClient.probe(host: printer.host, port: printer.port, timeout: 5)
        let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
        if ok {
            return (true, "连接成功 · \(printer.endpoint) · \(ms) ms")
        }
        return (false, "无法连接 \(printer.endpoint)，请检查打印机电源、IP 和端口")
    }

    // MARK: 发送

    /// 把已经编码好的打印数据送到打印机。
    static func send(
        printer: PrinterConfig,
        payload: Data,
        jobName: String,
        copies: Int,
        log: @escaping (PrintLogEntry.Level, String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard !printer.host.isEmpty else { throw TransportError.badHost }
        guard !payload.isEmpty else { throw TransportError.emptyPayload }

        switch printer.proto {
        case .raw:
            try await sendRAW(printer: printer, payload: payload, log: log, progress: progress)
        case .lpr:
            try await sendLPR(
                printer: printer,
                payload: payload,
                jobName: jobName,
                log: log,
                progress: progress
            )
        case .ipp:
            try await sendIPP(
                printer: printer,
                payload: payload,
                jobName: jobName,
                copies: copies,
                log: log,
                progress: progress
            )
        }
    }

    // MARK: RAW 9100

    private static func sendRAW(
        printer: PrinterConfig,
        payload: Data,
        log: @escaping (PrintLogEntry.Level, String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let client = SocketClient()
                defer { client.close() }
                do {
                    log(.info, "正在连接 \(printer.endpoint)…")
                    try client.connect(host: printer.host, port: printer.port, timeout: 6)

                    if printer.format == .bridge {
                        var outgoing = payload
                        let greeting = client.receiveGreeting(timeout: 1.8)
                        if let greeting, greeting.uppercased().contains("V2") {
                            log(.success, "电脑端桥接已就绪（支持 A5 / 自定义纸张）")
                        } else {
                            outgoing = bridgeDowngrade(payload)
                            if greeting?.hasPrefix("LPBRIDGE") == true {
                                log(.warning, "电脑端桥接为旧版：本次按电脑默认纸张打印。")
                            } else {
                                log(.warning, "没有收到桥接程序的握手信息，仍尝试按旧版协议发送。")
                            }
                        }

                        log(.info, "开始发送电脑桥接数据 \(Format.bytes(outgoing.count))")
                        try client.send(outgoing, timeout: 90) { p in
                            progress(p)
                        }

                        // 有的桥接程序会在接收完后回一行状态；没有也不影响。
                        if let reply = client.receiveGreeting(timeout: 1.0), !reply.isEmpty {
                            log(.info, "电脑桥接返回：\(reply)")
                        }
                        log(.success, "电脑桥接数据发送完成")
                        continuation.resume()
                        return
                    }

                    // 直连 RAW 时先听一下握手：避免把 PCL 数据发给电脑桥接程序，
                    // 最后只得到一个难以理解的 Broken pipe。
                    if let greeting = client.receiveGreeting(timeout: 0.8),
                       greeting.hasPrefix("LPBRIDGE1") || greeting.hasPrefix("LPBRIDGE2") {
                        throw TransportError.bridgeMismatch
                    }

                    log(.success, "已连接 RAW 端口，开始发送 \(Format.bytes(payload.count))")
                    try client.send(payload, timeout: 90) { p in
                        progress(p)
                    }
                    log(.success, "打印数据发送完成")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// LPBRIDGE2 -> LPBRIDGE1：旧版电脑桥接不支持纸张描述，只保留份数。
    private static func bridgeDowngrade(_ v2: Data) -> Data {
        guard v2.count >= 15 else { return v2 }
        var out = v2
        out[8] = 0x31 // '1'
        out.removeSubrange(10..<15) // 去掉纸张类型 + 宽高（保留第 9 字节份数）
        return out
    }

    // MARK: LPR / LPD 515

    private static func sendLPR(
        printer: PrinterConfig,
        payload: Data,
        jobName: String,
        log: @escaping (PrintLogEntry.Level, String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let client = SocketClient()
                defer { client.close() }
                do {
                    log(.info, "正在连接 \(printer.endpoint)…")
                    try client.connect(host: printer.host, port: printer.port, timeout: 6)

                    var queue = printer.queue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if queue.isEmpty { queue = "lp" }

                    // 1. 接收打印任务
                    var command = Data([0x02])
                    command.append(contentsOf: Array(queue.utf8))
                    command.append(0x0A)
                    try client.send(command, timeout: 10)
                    try expectAck(client, step: "打印机接收任务")
                    log(.success, "LPD 队列 \(queue) 已接收任务")

                    // 2. 控制文件（RFC 1179：02 Count SP Name LF）
                    let suffix = String(format: "%03d", Int(Date().timeIntervalSince1970) % 1000)
                    let hostTag = "iPhone"
                    let controlName = "cfA\(suffix)\(hostTag)"
                    let dataName = "dfA\(suffix)\(hostTag)"
                    let safeJobName = lprJobName(jobName)

                    var controlText = ""
                    controlText += "H\(hostTag)\n"
                    controlText += "P\(hostTag)\n"
                    controlText += "J\(safeJobName)\n"
                    controlText += "N\(safeJobName)\n"
                    controlText += "l\(dataName)\n"      // 小写 L：原样打印二进制数据
                    controlText += "U\(dataName)\n"      // 打印后删除数据文件

                    let control = Data(controlText.utf8)

                    var controlHeader = Data([0x02])
                    controlHeader.append(contentsOf: Array(String(control.count).utf8))
                    controlHeader.append(contentsOf: Array(" \(controlName)\n".utf8))
                    try client.send(controlHeader, timeout: 10)
                    // RFC 1179：文件命令本身有一次 ack，文件内容 + NUL 之后还有一次。
                    // 少数设备只回后一次，所以命令 ack 用短超时并允许缺失。
                    try expectAck(client, step: "控制文件命令", timeout: 3, optional: true)
                    try client.send(control, timeout: 10)
                    try client.send(Data([0x00]), timeout: 10)
                    try expectAck(client, step: "控制文件")
                    log(.success, "控制文件已提交（\(controlName)）")

                    // 3. 数据文件（03 Count SP Name LF）
                    var dataHeader = Data([0x03])
                    dataHeader.append(contentsOf: Array(String(payload.count).utf8))
                    dataHeader.append(contentsOf: Array(" \(dataName)\n".utf8))
                    try client.send(dataHeader, timeout: 10)
                    try expectAck(client, step: "数据文件命令", timeout: 3, optional: true)
                    try client.send(payload, timeout: 90) { p in
                        progress(p)
                    }
                    try client.send(Data([0x00]), timeout: 10)
                    try expectAck(client, step: "数据文件")
                    log(.success, "数据文件已提交（\(Format.bytes(payload.count))）")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// LPD 控制文件只保证 ASCII；把中文等字符替换掉，并限制长度。
    private static func lprJobName(_ raw: String) -> String {
        let ascii = raw.unicodeScalars.map { scalar -> String in
            (0x20...0x7E).contains(Int(scalar.value)) ? String(scalar) : "_"
        }.joined()
        let trimmed = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "LanPrint" }
        return String(trimmed.prefix(80))
    }

    private static func expectAck(
        _ client: SocketClient,
        step: String,
        timeout: TimeInterval = 15,
        optional: Bool = false
    ) throws {
        let ack: Data
        do {
            ack = try client.receive(exactly: 1, timeout: timeout)
        } catch let error as SocketError {
            if case .timeout = error, optional { return }
            throw error
        }
        guard let value = ack.first else {
            throw TransportError.lpr("\(step)：没有收到打印机响应")
        }
        if value != 0 {
            throw TransportError.lpr("\(step)：打印机返回错误码 0x\(String(format: "%02X", value))")
        }
    }

    // MARK: IPP 631

    private static func sendIPP(
        printer: PrinterConfig,
        payload: Data,
        jobName: String,
        copies: Int,
        log: @escaping (PrintLogEntry.Level, String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws {
        let path = printer.ippPath.hasPrefix("/") ? printer.ippPath : "/" + printer.ippPath
        guard let url = URL(string: "http://\(printer.host):\(printer.port)\(path)") else {
            throw TransportError.badURL
        }

        progress(0.2)
        var body = IPPBuilder()
        body.versionAndOperation()
        body.operationAttributes()
        body.attributeText(tag: 0x47, name: "attributes-charset", value: "utf-8")
        body.attributeText(tag: 0x48, name: "attributes-natural-language", value: "zh-cn")
        body.attributeText(
            tag: 0x45,
            name: "printer-uri",
            value: "ipp://\(printer.host):\(printer.port)\(path)"
        )
        body.attributeText(tag: 0x42, name: "requesting-user-name", value: "iPhone")
        body.attributeText(tag: 0x42, name: "job-name", value: jobName)
        body.attributeText(
            tag: 0x49,
            name: "document-format",
            value: printer.format.mimeType
        )
        // copies 属于 Job Attributes 组（0x02），不能放在 Operation 组里。
        body.jobAttributes()
        body.attributeInteger(name: "copies", value: Int32(max(1, copies)))
        body.endAttributes()
        body.raw(payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.timeoutInterval = 90
        request.httpBody = body.data

        log(.info, "正在连接 \(url.absoluteString)…")
        progress(0.35)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)

        do {
            let (responseData, response) = try await session.data(for: request)
            progress(0.95)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                throw TransportError.http(statusCode)
            }
            guard responseData.count >= 8 else {
                throw TransportError.ipp(0x0506)
            }
            let ippStatus = (UInt16(responseData[2]) << 8) | UInt16(responseData[3])
            if ippStatus != 0 {
                throw TransportError.ipp(ippStatus)
            }
            log(.success, "IPP 打印成功（HTTP \(statusCode)，状态 0x0000）")
            progress(1)
        } catch let error as TransportError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                throw TransportError.network("无法连接 \(printer.endpoint)（打印机未开机或 IPP 未启用）")
            case .timedOut:
                throw TransportError.network("IPP 请求超时（打印机忙或网络不稳定）")
            case .networkConnectionLost:
                throw TransportError.network("IPP 连接被打印机关闭")
            default:
                throw TransportError.network("IPP 请求失败：\(error.localizedDescription)")
            }
        } catch {
            throw TransportError.network("IPP 请求失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - IPP 编码

private struct IPPBuilder {

    private(set) var data = Data()

    mutating func raw(_ payload: Data) {
        data.append(payload)
    }

    private mutating func byte(_ value: UInt8) {
        data.append(value)
    }

    private mutating func u16(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private mutating func u32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private mutating func text(_ value: String) {
        data.append(contentsOf: Array(value.utf8))
    }

    /// 1.1 版本 + Print-Job(0x0002) + 随机 request-id。
    mutating func versionAndOperation() {
        byte(0x01)
        byte(0x01)
        u16(0x0002)
        u32(UInt32.random(in: 1...UInt32.max))
    }

    mutating func operationAttributes() {
        byte(0x01)
    }

    mutating func jobAttributes() {
        byte(0x02)
    }

    mutating func attributeText(tag: UInt8, name: String, value: String) {
        byte(tag)
        u16(UInt16(name.utf8.count))
        text(name)
        u16(UInt16(value.utf8.count))
        text(value)
    }

    mutating func attributeInteger(name: String, value: Int32) {
        byte(0x21)
        u16(UInt16(name.utf8.count))
        text(name)
        u16(4)
        u32(UInt32(bitPattern: value))
    }

    mutating func endAttributes() {
        byte(0x03)
    }
}

// MARK: - 小工具

enum Format {

    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 {
            return String(format: "%.1f KB", Double(count) / 1024)
        }
        return String(format: "%.2f MB", Double(count) / 1024 / 1024)
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}
