import Foundation
import Darwin
import Security

public actor Engine {
    private let executable: URL
    private let directory: URL
    private var process: Process?
    private var lock: Int32 = -1
    private var admin: OpenListClient?
    public private(set) var connection: DriveConnection?

    public init(executable: URL, directory: URL) {
        self.executable = executable
        self.directory = directory
    }

    public func start() async throws -> DriveConnection {
        if let connection, process?.isRunning == true { return connection }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        lock = Darwin.open(directory.appendingPathComponent("engine.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock); lock = -1 }
            throw DriveError.message("Another WPS Drive instance is already running.")
        }
        do {
            return try await startLocked()
        } catch {
            stop()
            throw error
        }
    }

    private func startLocked() async throws -> DriveConnection {
        let port = try Self.freePort()
        let config: [String: Any] = [
            "scheme": ["address": "127.0.0.1", "http_port": port, "https_port": -1],
            "database": ["type": "sqlite3", "db_file": directory.appendingPathComponent("data.db").path,
                         "table_prefix": "x_"],
            "jwt_secret": try Self.secret(), "token_expires_in": 48,
            "temp_dir": directory.appendingPathComponent("temp").path,
            "log": ["enable": false]
        ]
        let configURL = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        let output = try Self.run(executable, ["admin", "token", "--data", directory.path])
        guard let line = output.components(separatedBy: .newlines).first(where: { $0.contains("Admin token:") }),
              let range = line.range(of: "Admin token:") else {
            throw DriveError.message("Could not initialize the bundled OpenList engine.")
        }
        let token = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let administrator = OpenListClient(connection: DriveConnection(
            endpoint: endpoint, username: "", password: "", token: token
        ))
        let child = Process()
        let host = executable.deletingLastPathComponent().appendingPathComponent("WPSDriveEngineHost")
        if FileManager.default.isExecutableFile(atPath: host.path) {
            child.executableURL = host
            child.arguments = [executable.path, "server", "--data", directory.path]
        } else {
            child.executableURL = executable
            child.arguments = ["server", "--data", directory.path]
        }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        var ready = false
        var startupError = ""
        for _ in 0..<80 {
            guard child.isRunning else { throw DriveError.message("OpenList exited during startup.") }
            do {
                _ = try await administrator.json("/api/me", method: "GET")
                ready = true
                break
            } catch { startupError = error.localizedDescription }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        guard ready else { throw DriveError.message("OpenList startup timed out: \(startupError)") }
        admin = administrator
        let response = try await administrator.json("/api/admin/user/list", method: "GET")
        let users = response["content"] as? [[String: Any]] ?? []
        for var user in users where user["role"] as? Int == 1 {
            user["disabled"] = true
            _ = try await administrator.json("/api/admin/user/update", body: user)
        }
        // The default bootstrap password is never exposed to the user or used by the mount.
        for var user in users where user["role"] as? Int == 2 {
            user["password"] = try Self.secret()
            _ = try await administrator.json("/api/admin/user/update", body: user)
        }
        let credentialURL = directory.appendingPathComponent("mount-credentials.json")
        let old = try? DriveConnection.load(from: credentialURL)
        let password = try old?.password ?? Self.secret()
        for (username, basePath) in [("wps", "/WPS"), ("wps-volume", "/")] {
            var mountUser = users.first { $0["username"] as? String == username } ?? [:]
            mountUser["username"] = username
            mountUser["password"] = password
            mountUser["role"] = 0
            mountUser["base_path"] = basePath
            mountUser["permission"] = 1019
            mountUser["disabled"] = false
            let route = mountUser["id"] == nil ? "create" : "update"
            _ = try await administrator.json("/api/admin/user/\(route)", body: mountUser)
        }
        let login = try await administrator.json("/api/auth/login", body: ["username": "wps", "password": password])
        guard let userToken = login["token"] as? String else { throw DriveError.authentication }
        let credentials = DriveConnection(
            endpoint: endpoint, username: "wps", password: password, token: userToken,
            volumeUsername: "wps-volume"
        )
        try credentials.save(to: credentialURL)
        connection = credentials
        return credentials
    }

    public func configureWPS(cookie: String, mode: String, userAgent: String) async throws {
        let addition: [String: Any] = [
            "root_folder_path": "/", "cookie": cookie, "mode": mode, "custom_ua": userAgent
        ]
        try await storage(driver: "WPS", addition: addition)
        guard let connection else { throw DriveError.unavailable }
        _ = try await OpenListClient(connection: connection).list("/")
    }

    public func configureLocal(root: URL) async throws {
        try await storage(driver: "Local", addition: [
            "root_folder_path": root.path, "show_hidden": true,
            "mkdir_perm": "0755", "thumbnail": false
        ])
        connection?.driver = "Local"
    }

    public func hasWPS() async throws -> Bool {
        guard let admin else { throw DriveError.unavailable }
        let response = try await admin.json("/api/admin/storage/list", method: "GET")
        return (response["content"] as? [[String: Any]] ?? [])
            .contains { $0["mount_path"] as? String == "/WPS" && $0["driver"] as? String == "WPS" }
    }

    private func storage(driver: String, addition: [String: Any]) async throws {
        guard let admin else { throw DriveError.unavailable }
        let response = try await admin.json("/api/admin/storage/list", method: "GET")
        let storages = response["content"] as? [[String: Any]] ?? []
        var storage = storages.first { $0["mount_path"] as? String == "/WPS" } ?? [:]
        storage["mount_path"] = "/WPS"
        storage["driver"] = driver
        storage["addition"] = String(decoding: try JSONSerialization.data(withJSONObject: addition), as: UTF8.self)
        storage["cache_expiration"] = 0
        storage["webdav_policy"] = "native_proxy"
        storage["disabled"] = false
        let route = storage["id"] == nil ? "create" : "update"
        _ = try await admin.json("/api/admin/storage/\(route)", body: storage)
    }

    public func stop() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        admin = nil
        connection = nil
        if lock >= 0 { flock(lock, LOCK_UN); close(lock); lock = -1 }
    }

    private static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DriveError.message("Could not generate local credentials.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func freePort() throws -> Int {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw DriveError.unavailable }
        defer { close(handle) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw DriveError.unavailable }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &size) }
        }
        guard status == 0 else { throw DriveError.unavailable }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let command = Process()
        command.executableURL = executable
        command.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["OPENLIST_ADMIN_PASSWORD"] = try secret()
        command.environment = environment
        let pipe = Pipe()
        command.standardOutput = pipe
        command.standardError = pipe
        try command.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else {
            throw DriveError.message("OpenList initialization failed (exit \(command.terminationStatus)).")
        }
        return String(decoding: output, as: UTF8.self)
    }
}
