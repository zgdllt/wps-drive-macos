import AppKit
import FileProvider
import Darwin

extension AppDelegate {
    func runNativeVerification(directory: URL, executable: URL) async {
        let verifier = NativeVerification(
            directory: directory, executable: executable,
            onActivation: { self.showNativeActivationRequired() }
        )
        let passed = await verifier.run()
        finishVerification(status: passed ? 0 : 1)
    }
}

@MainActor
private final class NativeVerification {
    private let directory: URL
    private let executable: URL
    private let onActivation: () -> Void
    private var lines: [String] = []
    private var output: URL { directory.appendingPathComponent("native-verification.txt") }

    init(directory: URL, executable: URL, onActivation: @escaping () -> Void) {
        self.directory = directory
        self.executable = executable
        self.onActivation = onActivation
    }

    private func report(_ text: String) {
        lines.append(text)
        NSLog("WPS verification: %@", text)
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }

    func run() async -> Bool {
        let identifier = "wps-verification-" + UUID().uuidString.lowercased()
        let fixture = directory.appendingPathComponent(identifier)
        let remote = fixture.appendingPathComponent("remote/Workspace")
        let engine = Engine(executable: executable, directory: fixture.appendingPathComponent("engine"))
        let domain = NSFileProviderDomain(identifier: .init(identifier), displayName: "WPS Verification")
        domain.supportsSyncingTrash = false
        var passed = false
        report("START: isolated local fixture; no WPS account or SeaDrive data is used")
        do {
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            let content = Data(repeating: 0x57, count: 256 * 1024)
            try content.write(to: remote.appendingPathComponent("cloud.txt"))
            _ = try await engine.start()
            try await engine.configureLocal(root: remote.deletingLastPathComponent())
            guard let connection = await engine.connection else { throw DriveError.unavailable }
            report("PASS: isolated engine started")
            try await callback { NSFileProviderManager.add(domain, completionHandler: $0) }
            report("PASS: native domain registered")
            let activationDeadline = Date().addingTimeInterval(300)
            var waiting = false
            while true {
                let domains: [NSFileProviderDomain] = try await withCheckedThrowingContinuation { continuation in
                    NSFileProviderManager.getDomainsWithCompletionHandler {
                        if let error = $1 { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: $0) }
                    }
                }
                if domains.first(where: { $0.identifier == domain.identifier })?.userEnabled == true { break }
                if !waiting {
                    report("ACTIVATION_REQUIRED: enable WPS Drive in System Settings > Login Items > File Providers")
                    onActivation()
                    waiting = true
                }
                guard Date() < activationDeadline else {
                    throw DriveError.message("Timed out waiting for normal File Provider activation")
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard let manager = NSFileProviderManager(for: domain) else { throw DriveError.unavailable }
            let session = try await ProviderSession.connect(manager)
            try await session.configure(connection)
            report("PASS: restricted system XPC service configured provider without App Group")
            let root: URL = try await withCheckedThrowingContinuation { continuation in
                manager.getUserVisibleURL(for: .rootContainer) { url, error in
                    if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: error ?? DriveError.unavailable) }
                }
            }
            report("PASS: native root obtained")
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let names = try await Task.detached {
                try FileManager.default.contentsOfDirectory(atPath: root.path)
            }.value
            guard names.contains("Workspace") else { throw DriveError.message("Fixture folder not enumerated") }
            let folder = root.appendingPathComponent("Workspace")
            _ = try await Task.detached {
                try FileManager.default.contentsOfDirectory(atPath: folder.path)
            }.value
            let file = folder.appendingPathComponent("cloud.txt")
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw DriveError.message("Missing placeholder") }
            report("INFO: placeholder flags=\(info.st_flags), blocks=\(info.st_blocks), size=\(info.st_size)")
            guard info.st_flags & UInt32(SF_DATALESS) != 0 else {
                throw DriveError.message("Initial cloud file was not a dataless placeholder")
            }
            report("PASS: initial file is a dataless placeholder")
            let downloaded = try await Task.detached { try Data(contentsOf: file) }.value
            guard downloaded == content else { throw DriveError.message("Hydrated data mismatch") }
            report("PASS: on-demand native file read matched backend")
            try await callback { manager.waitForStabilization(completionHandler: $0) }
            let itemID = try await itemIdentifier(for: file)
            try await callback { manager.evictItem(identifier: itemID, completionHandler: $0) }
            guard lstat(file.path, &info) == 0 else { throw DriveError.missing }
            guard info.st_flags & UInt32(SF_DATALESS) != 0 else {
                throw DriveError.message("Eviction did not produce a dataless file")
            }
            guard try Data(contentsOf: remote.appendingPathComponent("cloud.txt")) == content else {
                throw DriveError.message("Eviction changed the backend")
            }
            report("PASS: remove download evicted local content and preserved backend file")
            try await session.setPinned([itemID.rawValue], value: true)
            try await callback { manager.waitForStabilization(completionHandler: $0) }
            guard lstat(file.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else {
                throw DriveError.message("Keep downloaded did not hydrate the file")
            }
            report("PASS: keep downloaded hydrated a dataless file without opening it")
            try await session.release([itemID.rawValue])
            guard lstat(file.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 else {
                throw DriveError.message("Unpin and eviction did not release local content")
            }
            report("PASS: cancel keep downloaded and remove download released local content")
            let fetchedAgain = try await Task.detached { try Data(contentsOf: file) }.value
            guard fetchedAgain == content else { throw DriveError.message("Re-download failed") }
            report("PASS: evicted file downloaded again")
            let folderID = try await itemIdentifier(for: folder)
            try await session.setPinned([itemID.rawValue], value: true)
            try await callback { manager.waitForStabilization(completionHandler: $0) }
            try await session.release([folderID.rawValue])
            guard lstat(file.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 else {
                throw DriveError.message("Folder release did not clear the child pin")
            }
            try await session.setPinned([folderID.rawValue], value: true)
            try await callback { manager.waitForStabilization(completionHandler: $0) }
            guard lstat(file.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else {
                throw DriveError.message("Folder keep did not propagate to the child")
            }
            try await session.release([folderID.rawValue])
            report("PASS: folder release clears child pins; folder keep inherits to descendants")

            if CommandLine.arguments.contains("--finder-self-test") {
                _ = try await Task.detached { try Data(contentsOf: file) }.value
                NSWorkspace.shared.activateFileViewerSelecting([file])
                report("WAITING_FOR_FINDER_ACTION: select Keep Downloaded, then Release Local Space on cloud.txt")
                let deadline = Date().addingTimeInterval(180)
                while true {
                    if lstat(file.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 { break }
                    guard Date() < deadline else {
                        throw DriveError.message("Finder release action did not evict within 180 seconds")
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                report("PASS: actual Finder action released local content")
            }

            let created = folder.appendingPathComponent("created.txt")
            let uploaded = Data("Native Finder upload verification".utf8)
            try await Task.detached { try uploaded.write(to: created) }.value
            try await callback { manager.waitForChanges(below: .rootContainer, completionHandler: $0) }
            guard try Data(contentsOf: remote.appendingPathComponent("created.txt")) == uploaded else {
                throw DriveError.message("Finder write not uploaded")
            }
            report("PASS: native file creation uploaded")
            let renamed = folder.appendingPathComponent("renamed.txt")
            try await Task.detached { try FileManager.default.moveItem(at: created, to: renamed) }.value
            try await callback { manager.waitForChanges(below: .rootContainer, completionHandler: $0) }
            guard FileManager.default.fileExists(atPath: remote.appendingPathComponent("renamed.txt").path) else {
                throw DriveError.message("Finder rename not uploaded")
            }
            report("PASS: native rename reached backend")
            try await Task.detached { try FileManager.default.removeItem(at: renamed) }.value
            try await callback { manager.waitForChanges(below: .rootContainer, completionHandler: $0) }
            guard !FileManager.default.fileExists(atPath: remote.appendingPathComponent("renamed.txt").path) else {
                throw DriveError.message("Finder deletion not uploaded")
            }
            report("PASS: native deletion reached backend")
            passed = true
        } catch {
            report("FAIL: \(error.localizedDescription)")
            report("DETAIL: \(error as NSError)")
        }
        do {
            try await callback { NSFileProviderManager.remove(domain, completionHandler: $0) }
            report("CLEANUP: fixture domain removed")
            await engine.stop()
            try FileManager.default.removeItem(at: fixture)
        } catch {
            report("CLEANUP_PENDING: \(error.localizedDescription)")
            await engine.stop()
            passed = false
        }
        report(passed ? "NATIVE_VERIFICATION_PASSED" : "NATIVE_VERIFICATION_FAILED")
        return passed
    }

    private func callback(_ operation: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation {
                if let error = $0 { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func itemIdentifier(for file: URL) async throws -> NSFileProviderItemIdentifier {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: file) { item, _, error in
                if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: error ?? DriveError.missing) }
            }
        }
    }
}
