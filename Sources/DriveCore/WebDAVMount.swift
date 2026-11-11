import Foundation
import NetFS

public enum WebDAVMount {
    public static func remoteURL(_ connection: DriveConnection) -> URL {
        connection.endpoint.appendingPathComponent(
            connection.volumeUsername == nil ? "dav" : "dav/WPS", isDirectory: true
        )
    }

    public static func mount(connection: DriveConnection, at directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let remote = remoteURL(connection)
        let username = connection.volumeUsername ?? connection.username
        let openOptions = NSMutableDictionary(dictionary: ["AllowLoopback": true, "UIOption": "NoUI"])
        let mountOptions = NSMutableDictionary(dictionary: ["MountAtMountDir": true, "SoftMount": true])
        var points: Unmanaged<CFArray>?
        var result = NetFSMountURLSync(
            remote as CFURL, directory as CFURL,
            username as CFString, connection.password as CFString,
            openOptions, mountOptions, &points
        )
        var mounted = points?.takeRetainedValue() as? [String]
        if result == EPERM {
            // NetAuth can reject a custom mount directory; let macOS allocate its normal volume path.
            points = nil
            result = NetFSMountURLSync(
                remote as CFURL, nil, username as CFString, connection.password as CFString,
                openOptions, nil, &points
            )
            mounted = points?.takeRetainedValue() as? [String]
        }
        guard result == 0 else {
            throw DriveError.message("macOS 挂载失败（\(result)）。")
        }
        return mounted?.first.map { URL(fileURLWithPath: $0) } ?? directory
    }

    public static func isMounted(_ directory: URL) -> Bool {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])?
            .contains { $0.standardizedFileURL == directory.standardizedFileURL } == true
    }

    public static func mountedSource(_ directory: URL) -> URL? {
        guard let source = NetFSCopyURLForRemountingVolume(directory as CFURL)?.takeRetainedValue() else {
            return nil
        }
        return source as URL
    }

    public static func sameServerPath(_ first: URL, _ second: URL) -> Bool {
        first.scheme == second.scheme && first.host == second.host && first.port == second.port &&
            first.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
            second.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
