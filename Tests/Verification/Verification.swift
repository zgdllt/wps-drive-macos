import Foundation
#if SWIFT_PACKAGE
import DriveCore
#endif

func require(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
    guard try condition() else { throw DriveError.message("FAIL: " + description) }
}

@main
struct Verification {
    static func main() async {
        do {
            try await catalogChecks()
            print("PASS: stable IDs, persisted pin state, rename, move, subtree deletion, filenames")
            try await engineChecks()
            print("PASS: authenticated loopback backend, upload, download, Unicode, rename, move, delete")
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func catalogChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("catalog.json")
        let catalog = try Catalog(file: file)
        let withoutDigest = try RemoteEntry(json: [
            "name": "a.txt", "size": 3, "is_dir": false, "modified": "2026-11-11", "hashinfo": "null"
        ])
        try require(withoutDigest.contentTag == "2026-11-11|3", "null hash uses modification version")
        let emptyDigest = try RemoteEntry(json: [
            "name": "a.txt", "size": 3, "is_dir": false, "modified": "changed", "hashinfo": "{\"sha1\":\"\"}"
        ])
        try require(emptyDigest.contentTag == "changed|3", "empty hash uses modification version")
        let withDigest = try RemoteEntry(json: [
            "name": "a.txt", "size": 3, "is_dir": false, "hash_info": ["sha1": "abc123"]
        ])
        try require(withDigest.hash.contains("abc123"), "structured digest preserved")
        let entry = RemoteEntry(name: "中文 test.txt", size: 12, isDirectory: false, modified: "2026-11-11")
        let initial = try await catalog.reconcile("root", entries: [entry])[0]
        try await catalog.setPinned(initial.id, true)
        let revision = await catalog.revision()
        let refreshed = try await catalog.reconcile("root", entries: [entry])[0]
        try require(initial.id == refreshed.id && refreshed.pinned == true, "identity and pin survived refresh")
        let unchanged = await catalog.revision()
        try require(unchanged == revision, "unchanged listing did not add changes")
        let reloaded = try Catalog(file: file)
        let persisted = try await reloaded.record(initial.id)
        try require(persisted == refreshed, "identity survived restart")

        let folders = try await catalog.reconcile("root", entries: [
            RemoteEntry(name: "a", size: 0, isDirectory: true),
            RemoteEntry(name: "b", size: 0, isDirectory: true)
        ])
        let first = folders.first { $0.remote.name == "a" }!
        let second = folders.first { $0.remote.name == "b" }!
        let child = try await catalog.reconcile(first.id, entries: [
            RemoteEntry(name: "data.txt", size: 1, isDirectory: false)
        ])[0]
        try await catalog.setPinned(child.id, true)
        try await catalog.setPinned(first.id, false, clearingDescendants: true)
        let releasedChild = try await catalog.record(child.id)
        try require(releasedChild.pinned == nil, "released folder clears child pin to inherited")
        try await catalog.setPinned(first.id, true, clearingDescendants: true)
        let inheritedChild = try await catalog.record(child.id)
        try require(inheritedChild.pinned == nil, "kept folder preserves child inheritance")
        try await catalog.relocate(first.id, parentID: "root", name: "renamed")
        let descendant = try await catalog.record(child.id)
        try require(descendant.path == "/renamed/data.txt", "folder rename updates descendants")
        let anchor = await catalog.revision()
        try await catalog.relocate(child.id, parentID: second.id, name: "data.txt")
        let old = try await catalog.changes(since: anchor, parentID: first.id)
        let new = try await catalog.changes(since: anchor, parentID: second.id)
        try require(old.1 == [child.id] && old.0.isEmpty, "old parent received removal")
        try require(new.0.map(\.id) == [child.id] && new.1.isEmpty, "new parent received addition")
        let beforeDeletion = await catalog.revision()
        _ = try await catalog.reconcile("root", entries: [])
        let removed = try await catalog.changes(since: beforeDeletion, parentID: nil)
        try require(Set(removed.1) == Set([first.id, second.id, child.id]), "subtree deletion journal")
        try require(try RemotePath.child("/资料", "file % #?.txt") == "/资料/file % #?.txt", "Unicode path")
        for invalid in ["..", ".", "a/b", ""] {
            do {
                _ = try RemotePath.child("/folder", invalid)
                throw DriveError.message("FAIL: accepted an escaping filename")
            } catch DriveError.message(let message) where message == "Invalid remote filename." {}
        }
    }

    private static func engineChecks() async throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".vendor/openlist")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw DriveError.message("Run scripts/fetch-engine.sh before verification.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WPSDriveTests-\(UUID().uuidString)")
        let remote = directory.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = Engine(executable: binary, directory: directory.appendingPathComponent("engine"))
        do {
            let connection = try await engine.start()
            try await engine.configureLocal(root: remote)
            let client = OpenListClient(connection: connection)
            try await client.mkdir("/资料")
            let source = directory.appendingPathComponent("source.txt")
            let content = Data("WPS Drive verification\n中文 / % # ?\n".utf8)
            try content.write(to: source)
            try await client.upload(source, to: "/资料/test % #?.txt")
            let files = try await client.list("/资料")
            try require(files.map(\.name) == ["test % #?.txt"], "upload preserved filename")
            let downloaded = directory.appendingPathComponent("downloaded.txt")
            try await client.download("/资料/test % #?.txt", to: downloaded)
            try require(try Data(contentsOf: downloaded) == content, "download matched original")
            try await client.rename("/资料/test % #?.txt", to: "renamed.txt")
            try await client.move("/资料/renamed.txt", to: "/")
            let root = try await client.list("/")
            try require(root.contains { $0.name == "renamed.txt" }, "move completed")
            try await client.remove("/renamed.txt")
            let after = try await client.list("/")
            try require(!after.contains { $0.name == "renamed.txt" }, "delete completed")
            var unauthorized = URLRequest(url: connection.endpoint.appendingPathComponent("/dav/"))
            unauthorized.httpMethod = "PROPFIND"
            let (_, response) = try await URLSession.shared.data(for: unauthorized)
            try require((response as? HTTPURLResponse)?.statusCode == 401, "unauthenticated WebDAV rejected")
            try require(connection.endpoint.host == "127.0.0.1", "backend uses loopback")
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }
}
