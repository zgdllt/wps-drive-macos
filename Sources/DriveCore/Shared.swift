import Foundation

public enum DrivePaths {
    public static let domain = "wps-personal"

    public static func appDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("WPS Drive")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

}

public enum DriveError: LocalizedError {
    case message(String)
    case authentication
    case missing
    case conflict
    case unavailable
    case collision
    case invalidAnchor
    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .authentication: return "Please sign in to WPS again."
        case .missing: return "The remote item no longer exists."
        case .conflict: return "The cloud file changed since it was downloaded."
        case .unavailable: return "The local cloud connection is unavailable."
        case .collision: return "A cloud item with that name already exists."
        case .invalidAnchor: return "The enumeration anchor has expired."
        }
    }
}

public struct DriveConnection: Codable, Equatable {
    public var endpoint: URL
    public var username: String
    public var password: String
    public var token: String
    public var driver: String
    public var volumeUsername: String?

    public init(endpoint: URL, username: String, password: String, token: String,
                driver: String = "WPS", volumeUsername: String? = nil) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.token = token
        self.driver = driver
        self.volumeUsername = volumeUsername
    }

    public static func file(in directory: URL, domain: String = DrivePaths.domain) -> URL {
        directory.appendingPathComponent("connection-\(domain).json")
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL) throws -> DriveConnection {
        guard FileManager.default.fileExists(atPath: url.path) else { throw DriveError.authentication }
        return try JSONDecoder().decode(DriveConnection.self, from: Data(contentsOf: url))
    }
}

public enum RemotePath {
    public static func child(_ parent: String, _ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\0") else { throw DriveError.message("Invalid remote filename.") }
        return parent == "/" ? "/" + name : parent + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let result = (path as NSString).deletingLastPathComponent
        return result.isEmpty ? "/" : result
    }
}
