import Foundation

public struct RemoteEntry: Equatable, Codable {
    public var name: String
    public var size: Int64
    public var isDirectory: Bool
    public var modified: String
    public var created: String
    public var hash: String

    public init(name: String, size: Int64, isDirectory: Bool, modified: String = "",
                created: String = "", hash: String = "") {
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.modified = modified
        self.created = created
        self.hash = hash
    }

    public init(json: [String: Any]) throws {
        guard let name = json["name"] as? String,
              let isDirectory = json["is_dir"] as? Bool else {
            throw DriveError.message("Invalid file listing from OpenList.")
        }
        self.name = name
        self.size = (json["size"] as? NSNumber)?.int64Value ?? 0
        self.isDirectory = isDirectory
        self.modified = json["modified"] as? String ?? ""
        self.created = json["created"] as? String ?? ""
        var hashes = json["hash_info"] as? [String: String] ?? json["hashinfo"] as? [String: String] ?? [:]
        if hashes.isEmpty, let encoded = json["hashinfo"] as? String,
           let parsed = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: String] {
            hashes = parsed
        }
        hashes = hashes.filter { !$0.value.isEmpty && $0.value != "null" }
        if !hashes.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: hashes, options: .sortedKeys)
            self.hash = String(decoding: data, as: UTF8.self)
        } else {
            self.hash = ""
        }
    }

    public var contentTag: String {
        // OpenList drivers without a digest expose modification time and size.
        hash.isEmpty ? "\(modified)|\(size)" : hash
    }
}

public actor OpenListClient {
    public private(set) var connection: DriveConnection
    private let session: URLSession

    public init(connection: DriveConnection) {
        self.connection = connection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: configuration)
    }

    public func json(
        _ route: String, method: String = "POST", body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        do { return try await send(route, method: method, body: body) }
        catch DriveError.authentication {
            guard !connection.username.isEmpty, route != "/api/auth/login" else { throw DriveError.authentication }
            let result = try await send(
                "/api/auth/login", method: "POST",
                body: ["username": connection.username, "password": connection.password]
            )
            guard let token = result["token"] as? String else { throw DriveError.authentication }
            connection.token = token
            return try await send(route, method: method, body: body)
        }
    }

    private func send(
        _ route: String, method: String, body: [String: Any]?
    ) async throws -> [String: Any] {
        guard let url = URL(string: route, relativeTo: connection.endpoint)?.absoluteURL else {
            throw DriveError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(connection.token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        if route == "/api/me",
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = result["code"] as? Int, code == 500,
           let message = result["message"] as? String {
            throw DriveError.message("Local OpenList authentication: \(message)")
        }
        return try Self.decode(data, response: response)
    }

    public static func decode(_ data: Data, response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw DriveError.unavailable }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.message("Invalid OpenList response.")
        }
        let code = (json["code"] as? Int) ?? http.statusCode
        switch code {
        case 200: return json["data"] as? [String: Any] ?? [:]
        case 401, 403: throw DriveError.authentication
        case 404: throw DriveError.missing
        default:
            // Upstream error bodies can contain cookies or signed URLs; keep them out of Finder logs.
            throw DriveError.message("OpenList request failed (code \(code)).")
        }
    }

    public func list(_ path: String, refresh: Bool = true) async throws -> [RemoteEntry] {
        let result = try await json("/api/fs/list", body: ["path": path, "password": "", "refresh": refresh])
        let files = result["content"] as? [[String: Any]] ?? []
        return try files.map(RemoteEntry.init(json:))
    }

    public func metadata(_ path: String) async throws -> RemoteEntry {
        let result = try await json("/api/fs/get", body: ["path": path, "password": ""])
        return try RemoteEntry(json: result)
    }

    public func download(_ path: String, to destination: URL) async throws {
        var components = URLComponents(url: connection.endpoint, resolvingAgainstBaseURL: false)!
        components.path = "/dav" + path
        var request = URLRequest(url: components.url!)
        let credentials = Data("\(connection.username):\(connection.password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        // OpenList's native WebDAV proxy applies the WPS driver's download headers.
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.message("Downloading the cloud file failed.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public func upload(_ source: URL, to path: String) async throws {
        // Login tokens expire after 48 hours; renew before starting a streamed upload.
        _ = try await json("/api/me", method: "GET")
        var request = URLRequest(url: connection.endpoint.appendingPathComponent("/api/fs/put"))
        request.httpMethod = "PUT"
        request.setValue(connection.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        request.setValue(path.addingPercentEncoding(withAllowedCharacters: allowed), forHTTPHeaderField: "File-Path")
        request.setValue("false", forHTTPHeaderField: "As-Task")
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.upload(for: request, fromFile: source)
        _ = try Self.decode(data, response: response)
    }

    public func mkdir(_ path: String) async throws {
        _ = try await json("/api/fs/mkdir", body: ["path": path])
    }

    public func rename(_ path: String, to name: String) async throws {
        _ = try RemotePath.child(RemotePath.parent(path), name)
        _ = try await json("/api/fs/rename", body: ["path": path, "name": name])
    }

    public func move(_ path: String, to parent: String) async throws {
        let result = try await json("/api/fs/move", body: [
            "src_dir": RemotePath.parent(path), "dst_dir": parent,
            "names": [(path as NSString).lastPathComponent]
        ])
        for task in result["tasks"] as? [[String: Any]] ?? [] {
            guard let id = task["id"] as? String else {
                throw DriveError.message("OpenList did not return a move task identifier.")
            }
            var route = URLComponents()
            route.path = "/api/task/move/info"
            route.queryItems = [URLQueryItem(name: "tid", value: id)]
            while true {
                try Task.checkCancellation()
                let status = try await json(route.string!)
                guard let state = status["state"] as? Int else {
                    throw DriveError.message("OpenList did not return a move task state.")
                }
                if state == 2 { break }
                if state == 4 || state == 7 {
                    throw DriveError.message("The cloud move task did not complete.")
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    public func remove(_ path: String) async throws {
        _ = try await json("/api/fs/remove", body: [
            "dir": RemotePath.parent(path), "names": [(path as NSString).lastPathComponent]
        ])
    }
}
