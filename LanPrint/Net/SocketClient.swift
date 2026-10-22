import Foundation
import Darwin

// MARK: - 错误

enum SocketError: LocalizedError {
    case resolveFailed
    case connectFailed(String)
    case timeout
    case sendFailed(String)
    case receiveFailed(String)
    case closed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .resolveFailed:
            return "无法解析地址（请检查主机名或 IP）"
        case .connectFailed(let reason):
            return "连接失败：\(reason)"
        case .timeout:
            return "连接超时（打印机是否开机、网络是否正常）"
        case .sendFailed(let reason):
            return "发送失败：\(reason)"
        case .receiveFailed(let reason):
            return "接收失败：\(reason)"
        case .closed:
            return "连接被打印机关闭（可能不支持当前格式，或这是电脑桥接端口）"
        case .cancelled:
            return "已取消"
        }
    }
}

// MARK: - 阻塞式 TCP 客户端

/// 用 POSIX socket 实现的 TCP 客户端。
///
/// 为什么不用 `NWConnection`：打印一页 A4 光栅大约 1 MB，需要明确的
/// 发送进度和「写完再关」的语义，POSIX 的 send 循环更直接；同时连接超时
/// 用非阻塞 connect + poll 实现，避免卡住 75 秒。
final class SocketClient {

    private var fd: Int32 = -1

    deinit {
        close()
    }

    // MARK: 连接

    func connect(host: String, port: Int, timeout: TimeInterval = 5) throws {
        close()

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let list = result else {
            throw SocketError.resolveFailed
        }
        defer { freeaddrinfo(list) }

        var lastError = "未知错误"
        var cursor: UnsafeMutablePointer<addrinfo>? = list

        while let info = cursor {
            let candidate = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if candidate >= 0 {
                let oldFlags = fcntl(candidate, F_GETFL, 0)
                _ = fcntl(candidate, F_SETFL, oldFlags | O_NONBLOCK)

                var one: Int32 = 1
                setsockopt(
                    candidate,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &one,
                    socklen_t(MemoryLayout<Int32>.size)
                )

                let connectResult = Darwin.connect(candidate, info.pointee.ai_addr, info.pointee.ai_addrlen)

                if connectResult == 0 {
                    fd = candidate
                    return
                }

                if errno == EINPROGRESS {
                    var pfd = pollfd(fd: candidate, events: Int16(POLLOUT), revents: 0)
                    let wait = poll(&pfd, nfds_t(1), Int32(max(0.1, timeout) * 1000))

                    if wait > 0 {
                        var socketError: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(candidate, SOL_SOCKET, SO_ERROR, &socketError, &length)
                        if socketError == 0 {
                            fd = candidate
                            return
                        }
                        lastError = Self.describe(errno: socketError)
                    } else if wait == 0 {
                        lastError = "连接超时"
                    } else {
                        lastError = Self.describe(errno: errno)
                    }
                } else {
                    lastError = Self.describe(errno: errno)
                }

                Darwin.close(candidate)
            }
            cursor = info.pointee.ai_next
        }

        throw SocketError.connectFailed(lastError)
    }

    // MARK: 发送

    func send(_ data: Data, timeout: TimeInterval = 30, progress: ((Double) -> Void)? = nil) throws {
        guard fd >= 0 else { throw SocketError.connectFailed("尚未连接") }
        guard !data.isEmpty else { return }

        let total = data.count
        var sent = 0

        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while sent < total {
                let written = Darwin.send(fd, base.advanced(by: sent), total - sent, 0)
                if written > 0 {
                    sent += written
                    progress?(Double(sent) / Double(total))
                } else if written < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        if !waitWritable(timeout: timeout) { throw SocketError.timeout }
                    } else if errno == EINTR {
                        continue
                    } else {
                        throw SocketError.sendFailed(Self.describe(errno: errno))
                    }
                } else {
                    throw SocketError.closed
                }
            }
        }
    }

    // MARK: 接收

    func receive(exactly count: Int, timeout: TimeInterval = 10) throws -> Data {
        guard fd >= 0 else { throw SocketError.connectFailed("尚未连接") }
        var output = Data()
        while output.count < count {
            if !waitReadable(timeout: timeout) { throw SocketError.timeout }
            var buffer = [UInt8](repeating: 0, count: min(4096, count - output.count))
            let read = Darwin.recv(fd, &buffer, buffer.count, 0)
            if read > 0 {
                output.append(contentsOf: buffer.prefix(read))
            } else if read == 0 {
                throw SocketError.closed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                throw SocketError.receiveFailed(Self.describe(errno: errno))
            }
        }
        return output
    }

    // MARK: 桥接握手

    /// 连接后短暂等待电脑桥接程序主动发来的握手行（LPBRIDGE1 ...）。
    /// 没有握手时返回 nil，不会把超时当成错误。
    func receiveGreeting(timeout: TimeInterval = 1.5) -> String? {
        guard fd >= 0 else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        var bytes: [UInt8] = []

        while bytes.count < 128 {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = poll(&pfd, nfds_t(1), Int32(max(0.02, remaining) * 1000))
            if wait <= 0 { break }

            var byte: UInt8 = 0
            let read = Darwin.recv(fd, &byte, 1, 0)
            if read > 0 {
                bytes.append(byte)
                if byte == 0x0A { break }
            } else if read == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                break
            }
        }

        guard !bytes.isEmpty else { return nil }
        let text = String(bytes: bytes, encoding: .ascii) ?? String(decoding: bytes, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 关闭

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: 工具

    private func waitWritable(timeout: TimeInterval) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&pfd, nfds_t(1), Int32(max(0.05, timeout) * 1000)) > 0
    }

    private func waitReadable(timeout: TimeInterval) -> Bool {        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, nfds_t(1), Int32(max(0.05, timeout) * 1000)) > 0
    }

    private static func describe(errno code: Int32) -> String {
        switch code {
        case ECONNREFUSED:
            return "连接被拒绝（打印机未开机或端口未开放）"
        case EHOSTUNREACH:
            return "主机不可达（检查 IP 和 Wi-Fi）"
        case ENETUNREACH:
            return "网络不可达（检查是否连在同一局域网）"
        case ETIMEDOUT:
            return "连接超时"
        case ECONNRESET:
            return "连接被打印机重置（可能不支持当前格式，或这是电脑桥接端口）"
        case EPIPE:
            return "打印机关闭了连接（可能不支持当前格式，或这是电脑桥接端口）"
        case EADDRNOTAVAIL:
            return "地址不可用"
        default:
            return String(cString: strerror(code))
        }
    }

    // MARK: 探测

    /// 只做一次带超时的 TCP 连接探测（扫描用）。
    static func probe(host: String, port: Int, timeout: TimeInterval = 0.6) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let client = SocketClient()
                do {
                    try client.connect(host: host, port: port, timeout: timeout)
                    client.close()
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    struct BridgeProbe {
        let connected: Bool
        let greeting: String?
    }

    /// 连接 9100 并读取电脑桥接程序发来的握手信息。
    static func probeBridge(
        host: String,
        port: Int,
        connectTimeout: TimeInterval = 3,
        greetingTimeout: TimeInterval = 1.2
    ) async -> BridgeProbe {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let client = SocketClient()
                do {
                    try client.connect(host: host, port: port, timeout: connectTimeout)
                    let greeting = client.receiveGreeting(timeout: greetingTimeout)
                    client.close()
                    continuation.resume(returning: BridgeProbe(connected: true, greeting: greeting))
                } catch {
                    client.close()
                    continuation.resume(returning: BridgeProbe(connected: false, greeting: nil))
                }
            }
        }
    }
}

// MARK: - 本机网络

enum NetworkInfo {

    /// 当前 Wi-Fi / 以太网的 IPv4 地址。
    static func localIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let head = pointer else { return nil }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        var fallback: String?

        while let item = cursor {
            let ifa = item.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(addr.pointee.sa_len)
                if getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.isEmpty, ip != "127.0.0.1" {
                        if name == "en0" || name == "en1" {
                            return ip
                        }
                        if fallback == nil { fallback = ip }
                    }
                }
            }
            cursor = ifa.ifa_next
        }
        return fallback
    }

    /// 由本机 IP 推网段前缀：192.168.3.252 -> 192.168.3.
    static func subnetPrefix(from ip: String) -> String {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return "192.168.1." }
        return "\(parts[0]).\(parts[1]).\(parts[2])."
    }
}
