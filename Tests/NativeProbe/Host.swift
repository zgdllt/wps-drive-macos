import AppKit
import FileProvider
import Darwin

@main
struct ProbeMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var result: [String] = []
    private var finished = false
    private var activeDomain: NSFileProviderDomain?
    private let status = NSTextField(labelWithString: "Testing an isolated File Provider…")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "WPS Native Probe"
        status.frame = NSRect(x: 24, y: 60, width: 380, height: 30)
        window.contentView?.addSubview(status)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await run() }
        Task {
            guard !CommandLine.arguments.contains("--activate") else { return }
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if !finished {
                report("FAIL: system callback timed out after 45 seconds")
                exit(2)
            }
        }
    }

    private func report(_ line: String) {
        result.append(line)
        print(line)
        fflush(stdout)
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WPS Drive/native-probe.txt")
        try? result.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    private func callback(_ operation: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation {
                if let error = $0 { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func savedDomain(_ identifier: NSFileProviderDomainIdentifier) async throws -> NSFileProviderDomain? {
        let domains: [NSFileProviderDomain] = try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler {
                if let error = $1 { continuation.resume(throwing: error) }
                else { continuation.resume(returning: $0) }
            }
        }
        return domains.first { $0.identifier == identifier }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let activeDomain else { return .terminateNow }
        Task {
            try? await callback { NSFileProviderManager.remove(activeDomain, completionHandler: $0) }
            self.activeDomain = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func run() async {
        let domain = NSFileProviderDomain(
            identifier: .init("wps-bare-probe"), displayName: "WPS Native Probe"
        )
        domain.supportsSyncingTrash = false
        var added = false
        var success = false
        report("START: ad-hoc signature; no App Group; synthetic content only")
        do {
            try await callback { NSFileProviderManager.add(domain, completionHandler: $0) }
            added = true
            activeDomain = domain
            report("PASS: domain registered")
            if let saved = try await savedDomain(domain.identifier) {
                report("INFO: userEnabled=\(saved.userEnabled), disconnected=\(saved.isDisconnected)")
                if !saved.userEnabled && CommandLine.arguments.contains("--activate") {
                    status.stringValue = "请在系统设置启用 WPS Native Probe"
                    report("ACTIVATION_REQUIRED: waiting for normal system activation")
                    while try await savedDomain(domain.identifier)?.userEnabled == false {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    report("INFO: domain activated; resuming isolated verification")
                    status.stringValue = "Testing an isolated File Provider…"
                }
            }
            guard let manager = NSFileProviderManager(for: domain) else {
                throw NSError(domain: "Probe", code: 1)
            }
            let root: URL = try await withCheckedThrowingContinuation { continuation in
                manager.getUserVisibleURL(for: .rootContainer) { url, error in
                    if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "Probe", code: 2)) }
                }
            }
            report("PASS: root URL returned")
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let names = try await Task.detached {
                try FileManager.default.contentsOfDirectory(atPath: root.path)
            }.value
            guard names.contains("probe.txt") else { throw NSError(domain: "Probe", code: 3) }
            report("PASS: placeholder enumerated")
            let file = root.appendingPathComponent("probe.txt")
            let content = try await Task.detached { try Data(contentsOf: file) }.value
            guard content == Data(repeating: 0x57, count: 256 * 1024) else {
                throw NSError(domain: "Probe", code: 4)
            }
            report("PASS: native on-demand read")
            try await callback { manager.waitForStabilization(completionHandler: $0) }
            try await callback { manager.evictItem(identifier: .init("probe"), completionHandler: $0) }
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 else {
                throw NSError(domain: "Probe", code: 5)
            }
            report("PASS: native eviction produced dataless placeholder")
            let fetched = try await Task.detached { try Data(contentsOf: file) }.value
            guard fetched == content else { throw NSError(domain: "Probe", code: 6) }
            report("PASS: evicted file re-downloaded")
            success = true
        } catch {
            let error = error as NSError
            report("FAIL: \(error.domain) \(error.code): \(error.localizedDescription)")
            report("DETAIL: \(error)")
        }
        if added {
            do {
                try await callback { NSFileProviderManager.remove(domain, completionHandler: $0) }
                activeDomain = nil
                report("CLEANUP: isolated domain removed")
            } catch { report("CLEANUP_PENDING: \(error.localizedDescription)"); success = false }
        }
        finished = true
        report(success ? "NATIVE_PROBE_PASSED" : "NATIVE_PROBE_FAILED")
        exit(success ? 0 : 1)
    }
}
