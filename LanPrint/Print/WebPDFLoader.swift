import Foundation
import UIKit
import WebKit

enum WebLoadError: LocalizedError {
    case invalidURL
    case timeout
    case loadFailed(String)
    case pdfFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "网址格式不正确（需要 http:// 或 https://）"
        case .timeout:
            return "网页加载超时（检查网址和网络）"
        case .loadFailed(let text):
            return "网页加载失败：\(text)"
        case .pdfFailed:
            return "网页内容无法转成 PDF"
        }
    }
}

/// 用隐藏的 WKWebView 打开网页，再整体导出成 PDF。
/// 这样长网页会自然分页，打印时按 PDF 页渲染即可。
@MainActor
final class WebPDFLoader: NSObject, WKNavigationDelegate {

    static func load(urlString: String) async throws -> Data {
        let loader = WebPDFLoader()
        return try await loader.runURL(urlString)
    }

    static func load(fileURL: URL) async throws -> Data {
        let loader = WebPDFLoader()
        return try await loader.runFile(fileURL)
    }

    private var webView: WKWebView?
    private var hostWindow: UIWindow?
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    // MARK: 入口

    private func runURL(_ raw: String) async throws -> Data {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WebLoadError.invalidURL }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw WebLoadError.invalidURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            begin(continuation: continuation, request: URLRequest(url: url, timeoutInterval: 30))
        }
    }

    private func runFile(_ url: URL) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            begin(continuation: continuation, fileURL: url)
        }
    }

    // MARK: 生命周期

    private func begin(
        continuation: CheckedContinuation<Data, Error>,
        request: URLRequest? = nil,
        fileURL: URL? = nil
    ) {
        self.continuation = continuation

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let web = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 1200),
            configuration: configuration
        )
        web.navigationDelegate = self
        web.isOpaque = true
        web.backgroundColor = .white
        web.scrollView.isScrollEnabled = false
        web.alpha = 0.01
        web.isUserInteractionEnabled = false

        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1024, height: 1200)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
            window.alpha = 0.01
            window.rootViewController = UIViewController()
            window.rootViewController?.view.backgroundColor = .white
            window.rootViewController?.view.addSubview(web)
            window.isHidden = false
            self.hostWindow = window
        } else if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            window.addSubview(web)
        }

        self.webView = web

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            self?.complete(.failure(WebLoadError.timeout))
        }

        if let request {
            web.load(request)
        } else if let fileURL {
            web.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        } else {
            complete(.failure(WebLoadError.invalidURL))
        }
    }

    private func capture() {
        guard !finished, let web = webView else { return }

        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            // 给 JS / 字体 / 图片一点时间完成布局
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !self.finished else { return }

            var contentHeight: CGFloat = 1200
            let script = """
            Math.max(
              document.body ? document.body.scrollHeight : 0,
              document.documentElement ? document.documentElement.scrollHeight : 0,
              document.body ? document.body.offsetHeight : 0,
              document.documentElement ? document.documentElement.offsetHeight : 0
            )
            """
            if let value = try? await web.evaluateJavaScript(script) {
                if let number = value as? NSNumber {
                    contentHeight = CGFloat(number.doubleValue)
                } else if let double = value as? Double {
                    contentHeight = CGFloat(double)
                }
            }

            contentHeight = min(max(contentHeight, 600), 30000)
            let width: CGFloat = 1024
            web.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)

            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !self.finished else { return }

            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: width, height: contentHeight)

            do {
                let data = try await web.createPDF(configuration: config)
                if data.isEmpty {
                    self.complete(.failure(WebLoadError.pdfFailed))
                } else {
                    self.complete(.success(data))
                }
            } catch {
                self.complete(.failure(WebLoadError.loadFailed(error.localizedDescription)))
            }
        }
    }

    private func complete(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(with: result)
        continuation = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        hostWindow?.isHidden = true
        hostWindow = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        capture()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        complete(.failure(WebLoadError.loadFailed(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        complete(.failure(WebLoadError.loadFailed(error.localizedDescription)))
    }
}
