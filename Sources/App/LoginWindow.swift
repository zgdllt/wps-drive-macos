import AppKit
import WebKit

@MainActor
final class LoginWindow: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    let window: NSWindow
    private let webView: WKWebView
    private let location = NSTextField(labelWithString: "kdocs.cn")
    private let useButton = NSButton(title: "使用此账号", target: nil, action: nil)
    var onCookie: ((String) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "登录 WPS"
        window.minSize = NSSize(width: 700, height: 540)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        useButton.target = self
        useButton.action = #selector(useAccount)
        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        location.textColor = .secondaryLabelColor
        let header = NSStackView(views: [location, NSView(), useButton])
        header.orientation = .horizontal
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        let stack = NSStackView(views: [header, webView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        window.contentView = stack
        header.heightAnchor.constraint(equalToConstant: 48).isActive = true
        window.center()
    }

    func show() {
        webView.load(URLRequest(url: URL(string: "https://www.kdocs.cn/latest")!))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func useAccount() {
        useButton.isEnabled = false
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self else { return }
                var values: [String: String] = [:]
                for cookie in cookies {
                    let host = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    guard ["wps.cn", "kdocs.cn"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
                    values[cookie.name] = cookie.value
                }
                let header = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
                self.useButton.isEnabled = true
                self.onCookie?(header)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        location.stringValue = webView.url?.host ?? "WPS"
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}
