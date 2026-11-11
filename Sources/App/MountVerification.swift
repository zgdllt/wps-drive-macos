import AppKit

extension AppDelegate {
    func runMountVerification(directory: URL, executable: URL) async {
        let fixture = directory.appendingPathComponent("mount-verification-\(UUID().uuidString)")
        let remote = fixture.appendingPathComponent("remote")
        let engine = Engine(executable: executable, directory: fixture.appendingPathComponent("engine"))
        var mount: URL?
        var log: [String] = []
        func report(_ line: String) {
            log.append(line)
            NSLog("WPS mount verification: %@", line)
            try? log.joined(separator: "\n").write(
                to: directory.appendingPathComponent("mount-verification.txt"), atomically: true, encoding: .utf8
            )
        }
        do {
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            let expected = Data("WPS Finder mount verification\n中文文件\n".utf8)
            try expected.write(to: remote.appendingPathComponent("read.txt"))
            let connection = try await engine.start()
            try await engine.configureLocal(root: remote)
            report("PASS: isolated backend started; no real cloud files used")
            let mounted = try await Task.detached {
                try WebDAVMount.mount(connection: connection, at: fixture.appendingPathComponent("WPS Verification"))
            }.value
            mount = mounted
            report("PASS: native macOS WebDAV volume mounted")
            guard mounted.lastPathComponent == "WPS" else {
                throw DriveError.message("Mounted volume name is not WPS")
            }
            guard let mountedSource = WebDAVMount.mountedSource(mounted),
                  WebDAVMount.sameServerPath(mountedSource, WebDAVMount.remoteURL(connection)) else {
                throw DriveError.message("Mounted source does not match WPS backend")
            }
            report("PASS: volume named WPS and source verified for recovery")
            let result = try await Task.detached {
                try Data(contentsOf: mounted.appendingPathComponent("read.txt"))
            }.value
            guard result == expected else { throw DriveError.message("Mounted read did not match backend") }
            report("PASS: file read through mounted filesystem")
            let source = mounted.appendingPathComponent("中文 write.txt")
            try await Task.detached { try expected.write(to: source) }.value
            guard try Data(contentsOf: remote.appendingPathComponent("中文 write.txt")) == expected else {
                throw DriveError.message("Mounted write did not reach backend")
            }
            report("PASS: Unicode file write reached backend")
            let renamed = mounted.appendingPathComponent("renamed.txt")
            try await Task.detached { try FileManager.default.moveItem(at: source, to: renamed) }.value
            guard FileManager.default.fileExists(atPath: remote.appendingPathComponent("renamed.txt").path) else {
                throw DriveError.message("Mounted rename did not reach backend")
            }
            report("PASS: rename through mounted filesystem")
            try await Task.detached { try FileManager.default.removeItem(at: renamed) }.value
            guard !FileManager.default.fileExists(atPath: remote.appendingPathComponent("renamed.txt").path) else {
                throw DriveError.message("Mounted delete did not reach backend")
            }
            report("PASS: deletion through mounted filesystem")
            report("MOUNT_VERIFICATION_PASSED")
        } catch { report("FAIL: \(error.localizedDescription)") }
        if let mount {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: mount)
            } catch { report("CLEANUP_PENDING: \(error.localizedDescription)") }
        }
        await engine.stop()
        if mount == nil || !WebDAVMount.isMounted(mount!) {
            try? FileManager.default.removeItem(at: fixture)
            report("CLEANUP: fixture removed")
        }
        finishVerification()
    }
}
