import AppKit
import FileProvider
import FinderSync
import CryptoKit

private struct AccountState: Codable {
    var domain: String
    var mode: String
    var native: Bool?
}

private struct MountedState: Codable {
    var local: URL
    var remote: URL
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var loginWindow: LoginWindow?
    private var engine: Engine?
    private var shared: URL?
    private var connection: DriveConnection?
    private var account: AccountState?
    private var timer: Timer?
    private var networkMount: URL?
    private var nativeMode = true
    private let modeControl = NSSegmentedControl(
        labels: ["原生云盘", "网络磁盘"], trackingMode: .selectOne, target: nil, action: nil
    )
    private var ready = false
    private var busy = false
    private let status = NSTextField(labelWithString: "正在启动…")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let indicator = NSProgressIndicator()
    private let loginButton = NSButton(title: "登录 WPS", target: nil, action: nil)
    private let finderButton = NSButton(title: "在访达中打开", target: nil, action: nil)
    private let refreshButton = NSButton()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification, object: nil
        )
        configureMenu()
        configureWindow()
        Task { await start() }
    }

    private func configureMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 WPS Drive", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 WPS Drive", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        main.addItem(item)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.badge.icloud", accessibilityDescription: "WPS Drive")
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "WPS Drive", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        let open = menu.addItem(withTitle: "在访达中打开", action: #selector(openFinder), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    private func configureWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "WPS Drive"
        window.isReleasedWhenClosed = false
        let image = NSImageView(image: NSImage(systemSymbolName: "externaldrive.badge.icloud", accessibilityDescription: "WPS Drive")!)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        image.contentTintColor = .systemRed
        let title = NSTextField(labelWithString: "WPS Drive")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let header = NSStackView(views: [image, title, NSView()])
        header.spacing = 14
        status.font = .systemFont(ofSize: 14, weight: .medium)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        modeControl.selectedSegment = nativeMode ? 0 : 1
        modeControl.setEnabled(
            Bundle.main.object(forInfoDictionaryKey: "WPSNativeProviderAvailable") as? Bool == true,
            forSegment: 0
        )
        modeControl.toolTip = "原生云盘支持按需下载和本地保留。"
        modeControl.target = self
        modeControl.action = #selector(selectMode)
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [indicator, status, NSView()])
        statusRow.spacing = 10
        loginButton.target = self
        loginButton.action = #selector(login)
        finderButton.target = self
        finderButton.action = #selector(openFinder)
        for button in [loginButton, finderButton] { button.bezelStyle = .rounded }
        loginButton.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
        loginButton.imagePosition = .imageLeading
        finderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        finderButton.imagePosition = .imageOnly
        finderButton.toolTip = "在访达中打开"
        finderButton.setAccessibilityLabel("在访达中打开")
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        refreshButton.bezelStyle = .rounded
        refreshButton.toolTip = "刷新云端文件"
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        let actions = NSStackView(views: [loginButton, finderButton, refreshButton, NSView()])
        actions.spacing = 10
        let divider = NSBox()
        divider.boxType = .separator
        let web = NSButton(title: "WPS 网页版", target: self, action: #selector(openWeb))
        let paste = NSButton(title: "使用 Cookie…", target: self, action: #selector(pasteCookie))
        let extensions = NSButton(title: "访达扩展…", target: self, action: #selector(openExtensions))
        for button in [web, paste, extensions] { button.bezelStyle = .inline }
        let footer = NSStackView(views: [web, paste, NSView(), extensions])
        footer.spacing = 12
        let stack = NSStackView(views: [header, modeControl, statusRow, detail, NSView(), actions, divider, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
        showWindow()
    }

    private func setState(_ text: String, detail: String = "", busy: Bool = false) {
        status.stringValue = text
        self.detail.stringValue = detail
        self.busy = busy
        busy ? indicator.startAnimation(nil) : indicator.stopAnimation(nil)
        loginButton.isEnabled = connection != nil && !busy
        finderButton.isEnabled = ready && !busy
        refreshButton.isEnabled = ready && !busy
        modeControl.isEnabled = !busy
    }

    private func start() async {
        setState("正在启动…", busy: true)
        do {
            let directory = try DrivePaths.appDirectory()
            shared = directory
            let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/openlist")
            let service = Engine(executable: executable, directory: directory.appendingPathComponent("engine"))
            engine = service
            if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--finder-self-test") {
                await runNativeVerification(directory: directory, executable: executable)
                return
            }
            if CommandLine.arguments.contains("--mount-test") {
                await runMountVerification(directory: directory, executable: executable)
                return
            }
            if CommandLine.arguments.contains("--cleanup-test-domains") {
                await cleanupTestDomains()
                finishVerification()
                return
            }
            connection = try await service.start()
            let mountStateURL = directory.appendingPathComponent("mounted-volume.json")
            if let saved = try? JSONDecoder().decode(MountedState.self, from: Data(contentsOf: mountStateURL)),
               WebDAVMount.isMounted(saved.local),
               let source = WebDAVMount.mountedSource(saved.local),
               WebDAVMount.sameServerPath(source, saved.remote) {
                networkMount = saved.local
                try NSWorkspace.shared.unmountAndEjectDevice(at: saved.local)
                networkMount = nil
            }
            let previousMount = directory.appendingPathComponent("Volumes/WPS")
            if WebDAVMount.isMounted(previousMount) {
                networkMount = previousMount
                try NSWorkspace.shared.unmountAndEjectDevice(at: previousMount)
                networkMount = nil
            }
            let accountURL = directory.appendingPathComponent("account.json")
            if FileManager.default.fileExists(atPath: accountURL.path) {
                account = try JSONDecoder().decode(AccountState.self, from: Data(contentsOf: accountURL))
                nativeMode = account?.native ?? true
                modeControl.selectedSegment = nativeMode ? 0 : 1
            }
            let probe = NSFileProviderDomain(identifier: .init("wps-probe"), displayName: "WPS Test")
            try? await removeDomain(probe)
            startRefreshTimer()
            if let account, try await service.hasWPS(), let connection {
                _ = try await OpenListClient(connection: connection).list("/")
                ready = true
                loginButton.title = "重新登录"
                if nativeMode {
                    try await connectDomain(account.domain)
                }
                setState("已连接 WPS", detail: accountDetail(account.mode))
            } else {
                setState("尚未登录", detail: "WPS")
            }
        } catch {
            setState("连接未完成", detail: humanMessage(error))
        }
    }

    @objc private func login() {
        guard !busy else { return }
        if loginWindow == nil {
            loginWindow = LoginWindow()
            loginWindow?.onCookie = { [weak self] cookie in
                Task { @MainActor in await self?.authenticate(cookie) }
            }
        }
        loginWindow?.show()
    }

    private func authenticate(_ cookie: String) async {
        guard let engine, let shared, connection != nil, !busy else { return }
        setState("正在验证 WPS 账号…", busy: true)
        do {
            guard !cookie.isEmpty else { throw DriveError.authentication }
            var request = URLRequest(url: URL(string: "https://account.kdocs.cn/api/v3/islogin")!)
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue(LoginWindow.userAgent, forHTTPHeaderField: "User-Agent")
            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let userID = result["userid"] as? NSNumber, userID.int64Value > 0 else {
                throw DriveError.authentication
            }
            let company = (result["companyid"] as? NSNumber)?.int64Value ?? 0
            let mode = result["is_company_account"] as? Bool == true ? "Business" : "Personal"
            let digest = SHA256.hash(data: Data("\(userID.int64Value):\(company):\(mode)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            let identifier = "wps-" + digest.prefix(24)
            if let account, account.domain != identifier {
                throw DriveError.message("当前版本连接一个 WPS 账号。请用原账号重新登录，避免混用本地文件。")
            }
            try await engine.configureWPS(cookie: cookie, mode: mode, userAgent: LoginWindow.userAgent)
            let state = AccountState(domain: identifier, mode: mode, native: nativeMode)
            try JSONEncoder().encode(state).write(to: shared.appendingPathComponent("account.json"), options: .atomic)
            account = state
            ready = true
            loginButton.title = "重新登录"
            loginWindow?.window.close()
            if nativeMode {
                do { try await connectDomain(identifier) }
                catch {
                    setState("原生云盘需要设置", detail: humanMessage(error))
                    return
                }
            }
            setState("已连接 WPS", detail: accountDetail(mode))
            openFinder()
        } catch {
            setState("登录未完成", detail: humanMessage(error))
        }
    }

    private func connectDomain(_ identifier: String) async throws {
        let domain = NSFileProviderDomain(identifier: .init(identifier), displayName: "WPS")
        domain.supportsSyncingTrash = false
        let domains = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NSFileProviderDomain], Error>) in
            NSFileProviderManager.getDomainsWithCompletionHandler {
                if let error = $1 { continuation.resume(throwing: error) }
                else { continuation.resume(returning: $0) }
            }
        }
        if !domains.contains(where: { $0.identifier == domain.identifier }) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSFileProviderManager.add(domain) {
                    if let error = $0 { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        guard let manager = NSFileProviderManager(for: domain), let connection else {
            throw DriveError.unavailable
        }
        let saved = try await registeredDomains().first { $0.identifier == domain.identifier }
        guard saved?.userEnabled == true else {
            throw DriveError.message("请在系统设置的“登录项与扩展”中启用 WPS Drive 文件提供程序，再点刷新。")
        }
        let session = try await ProviderSession.connect(manager)
        try await session.configure(connection)
        try await manager.signalEnumerator(for: .workingSet)
    }

    func registeredDomains() async throws -> [NSFileProviderDomain] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler {
                if let error = $1 { continuation.resume(throwing: error) }
                else { continuation.resume(returning: $0) }
            }
        }
    }

    func showNativeActivationRequired() {
        setState(
            "请启用 WPS Drive 文件提供程序",
            detail: "系统设置 > 通用 > 登录项与扩展 > 文件提供程序"
        )
    }

    private func removeDomain(_ domain: NSFileProviderDomain) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain) {
                if let error = $0 { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func startRefreshTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.signalRefresh() }
        }
    }

    private func signalRefresh() {
        guard nativeMode, ready, let account else { return }
        let domain = NSFileProviderDomain(identifier: .init(account.domain), displayName: "WPS")
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    @objc private func refresh() {
        guard ready, let account, !busy else { return }
        if !nativeMode {
            setState("正在刷新…", busy: true)
            Task {
                guard let connection else { return }
                do {
                    _ = try await OpenListClient(connection: connection).list("/")
                    setState("已连接 WPS", detail: accountDetail(account.mode))
                } catch { setState("连接需要恢复", detail: humanMessage(error)) }
            }
            return
        }
        setState("正在刷新…", busy: true)
        Task {
            do {
                try await connectDomain(account.domain)
                setState("已连接 WPS", detail: accountDetail(account.mode))
            } catch { setState("原生云盘需要设置", detail: humanMessage(error)) }
        }
    }

    @objc private func openFinder() {
        guard ready, let account, !busy else { showWindow(); return }
        if !nativeMode {
            guard let connection, let shared else { return }
            if let networkMount, WebDAVMount.isMounted(networkMount) {
                NSWorkspace.shared.open(networkMount)
                return
            }
            setState("正在连接访达…", busy: true)
            let mountpoint = shared.appendingPathComponent("Volumes/WPS")
            Task {
                do {
                    let mounted = try await Task.detached {
                        try WebDAVMount.mount(connection: connection, at: mountpoint)
                    }.value
                    networkMount = mounted
                    let state = MountedState(local: mounted, remote: WebDAVMount.remoteURL(connection))
                    let stateURL = shared.appendingPathComponent("mounted-volume.json")
                    try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
                    setState("已挂载 WPS", detail: accountDetail(account.mode))
                    NSWorkspace.shared.open(mounted)
                } catch { setState("访达连接未完成", detail: humanMessage(error)) }
            }
            return
        }
        let domain = NSFileProviderDomain(identifier: .init(account.domain), displayName: "WPS")
        NSFileProviderManager(for: domain)?.getUserVisibleURL(for: .rootContainer) { [weak self] url, error in
            Task { @MainActor in
                if let url { NSWorkspace.shared.open(url) }
                else if let error { self?.setState("访达尚未就绪", detail: self?.humanMessage(error) ?? "") }
            }
        }
    }

    @objc private func pasteCookie() {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = "使用 WPS 登录 Cookie"
        alert.informativeText = "粘贴 WPS 网页会话的 Cookie。它相当于登录凭据，仅在本机用于连接。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        field.placeholderString = "wps_sid=…"
        alert.accessoryView = field
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let cookie = field.stringValue
            field.stringValue = ""
            Task { await authenticate(cookie) }
        }
    }

    @objc private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        let anotherWindowIsVisible = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled)
        }
        if !anotherWindowIsVisible { NSApp.setActivationPolicy(.accessory) }
    }
    @objc private func openWeb() { NSWorkspace.shared.open(URL(string: "https://www.kdocs.cn/latest")!) }
    @objc private func openExtensions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    @objc private func selectMode() {
        guard !busy else { return }
        nativeMode = modeControl.selectedSegment == 0
        guard var account, let shared else { return }
        setState("正在切换…", busy: true)
        Task {
            do {
                if nativeMode { try await connectDomain(account.domain) }
                account.native = nativeMode
                try JSONEncoder().encode(account).write(
                    to: shared.appendingPathComponent("account.json"), options: .atomic
                )
                self.account = account
                setState("已连接 WPS", detail: accountDetail(account.mode))
            } catch { setState("原生云盘需要设置", detail: humanMessage(error)) }
        }
    }

    private func accountDetail(_ mode: String) -> String {
        (mode == "Business" ? "企业空间" : "个人空间") + (nativeMode ? " · 原生云盘" : " · 网络磁盘")
    }

    private func cleanupTestDomains() async {
        let domains = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NSFileProviderDomain], Error>) in
            NSFileProviderManager.getDomainsWithCompletionHandler {
                if let error = $1 { continuation.resume(throwing: error) }
                else { continuation.resume(returning: $0) }
            }
        }
        for domain in domains ?? [] where domain.identifier.rawValue == "wps-probe" ||
            domain.identifier.rawValue.hasPrefix("wps-verification-") {
            try? await removeDomain(domain)
        }
    }

    private func humanMessage(_ error: Error) -> String {
        if case DriveError.authentication = error { return "请先完成 WPS 登录，再点“使用此账号”。" }
        if error is URLError { return "网络连接失败，请稍后重试。" }
        return error.localizedDescription
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !busy else { return .terminateCancel }
        timer?.invalidate()
        Task {
            if let networkMount, WebDAVMount.isMounted(networkMount) {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: networkMount)
                    if let shared {
                        try? FileManager.default.removeItem(at: shared.appendingPathComponent("mounted-volume.json"))
                    }
                } catch {
                    setState("请先关闭正在使用的 WPS 文件", detail: humanMessage(error))
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await engine?.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func finishVerification(status: Int32 = 0) {
        busy = false
        exit(status)
    }
}
