import Foundation
import FileProvider

private actor OperationGate {
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { held = false }
        else { waiting.removeFirst().resume() }
    }
}

actor ProviderStore {
    private let domain: String
    private let gate = OperationGate()
    private var catalog: Catalog?
    private var client: OpenListClient?
    private var configuration: DriveConnection?
    private var scopedDirectory: URL?

    init(domain: String) { self.domain = domain }
    deinit { scopedDirectory?.stopAccessingSecurityScopedResource() }

    private func ownedDirectory() throws -> URL {
        if let scopedDirectory { return scopedDirectory }
        if #available(macOS 15.0, *) {
            let manager = NSFileProviderManager(
                for: NSFileProviderDomain(identifier: .init(domain), displayName: "WPS")
            )
            guard let manager else { throw DriveError.unavailable }
            let directory = try manager.stateDirectoryURL()
            guard directory.startAccessingSecurityScopedResource() else { throw DriveError.unavailable }
            // Catalog writes outlive the initiating call, so keep the scope for this store's lifetime.
            scopedDirectory = directory
            return directory
        }
        let directory = try DrivePaths.appDirectory().appendingPathComponent(domain, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func ownedCatalog() throws -> Catalog {
        if let catalog { return catalog }
        let directory = try ownedDirectory()
        let loaded = try Catalog(file: directory.appendingPathComponent("catalog-\(domain).json"))
        catalog = loaded
        return loaded
    }

    private func prepare() throws -> (Catalog, OpenListClient, DriveConnection) {
        let directory = try ownedDirectory()
        let connection = try DriveConnection.load(from: DriveConnection.file(in: directory, domain: domain))
        if configuration?.endpoint != connection.endpoint || configuration?.password != connection.password {
            client = OpenListClient(connection: connection)
            configuration = connection
        }
        return (try ownedCatalog(), client!, connection)
    }

    func configure(_ connection: DriveConnection) async throws {
        try await serialized {
            let directory = try ownedDirectory()
            try connection.save(to: DriveConnection.file(in: directory, domain: domain))
            configuration = nil
            client = nil
        }
    }

    private func serialized<T>(_ operation: () async throws -> T) async throws -> T {
        await gate.enter()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await gate.leave()
            return result
        } catch {
            await gate.leave()
            throw error
        }
    }

    private func refresh(_ id: String, catalog: Catalog, client: OpenListClient) async throws -> [FileRecord] {
        let parent = try await catalog.record(id)
        return try await catalog.reconcile(id, entries: client.list(parent.path))
    }

    private func refreshVisited(catalog: Catalog, client: OpenListClient) async throws {
        let parents = await catalog.visited().sorted {
            $0.path.split(separator: "/").count < $1.path.split(separator: "/").count
        }
        for parent in parents {
            guard (try? await catalog.record(parent.id)) != nil else { continue }
            _ = try await refresh(parent.id, catalog: catalog, client: client)
        }
    }

    func snapshot(_ id: String?) async throws -> ([FileRecord], Int64) {
        try await serialized {
            let (catalog, client, _) = try prepare()
            if let id {
                let items = try await refresh(id, catalog: catalog, client: client)
                return (items, await catalog.revision())
            }
            try await refreshVisited(catalog: catalog, client: client)
            return (await catalog.all(), await catalog.revision())
        }
    }

    func changes(since anchor: Int64, parentID: String?) async throws -> ([FileRecord], [String], Int64) {
        try await serialized {
            let (catalog, client, _) = try prepare()
            if let parentID {
                _ = try await refresh(parentID, catalog: catalog, client: client)
            } else {
                try await refreshVisited(catalog: catalog, client: client)
            }
            return try await catalog.changes(since: anchor, parentID: parentID)
        }
    }

    func revision() async throws -> Int64 {
        let (catalog, _, _) = try prepare()
        return await catalog.revision()
    }

    func record(_ id: String) async throws -> FileRecord {
        try await serialized {
            if id == "root" { return try await ownedCatalog().record(id) }
            let (catalog, client, _) = try prepare()
            let record = try await catalog.record(id)
            return try await catalog.update(id, remote: client.metadata(record.path))
        }
    }

    func download(_ id: String, directory: URL) async throws -> (URL, FileRecord) {
        try await serialized {
            let (catalog, client, _) = try prepare()
            let record = try await catalog.record(id)
            let before = try await client.metadata(record.path)
            let destination = directory.appendingPathComponent(UUID().uuidString)
            do {
                try await client.download(record.path, to: destination)
                let after = try await client.metadata(record.path)
                guard before.contentTag == after.contentTag else { throw DriveError.conflict }
                let updated = try await catalog.update(id, remote: after)
                return (destination, updated)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    func create(name: String, parentID: String, directory: Bool, contents: URL?) async throws -> FileRecord {
        try await serialized {
            let (catalog, client, configuration) = try prepare()
            let parent = try await catalog.record(parentID)
            let filename = configuration.driver == "WPS" && name.hasPrefix(".") ? "_" + name : name
            let path = try RemotePath.child(parent.path, filename)
            let children = try await refresh(parentID, catalog: catalog, client: client)
            if let existing = children.first(where: { $0.remote.name == filename }) {
                if directory && existing.remote.isDirectory { return existing }
                throw DriveError.collision
            }
            if directory {
                try await client.mkdir(path)
            } else if let contents {
                try await client.upload(contents, to: path)
            } else {
                let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try Data().write(to: empty)
                defer { try? FileManager.default.removeItem(at: empty) }
                try await client.upload(empty, to: path)
            }
            let result = try await refresh(parentID, catalog: catalog, client: client)
            guard let created = result.first(where: { $0.remote.name == filename }) else { throw DriveError.missing }
            return created
        }
    }

    func modify(
        id: String, contentVersion: Data, filename: String?, parentID: String?, contents: URL?,
        failOnConflict: Bool
    ) async throws -> FileRecord {
        try await serialized {
            let (catalog, client, _) = try prepare()
            var current = try await catalog.record(id)
            let remote = try await client.metadata(current.path)
            if let contents, Data(remote.contentTag.utf8) != contentVersion {
                if failOnConflict { throw DriveError.conflict }
                let original = current.remote.name as NSString
                let suffix = original.pathExtension
                let stem = suffix.isEmpty ? current.remote.name : original.deletingPathExtension
                let conflictName = stem + " (conflict " + UUID().uuidString + ")" +
                    (suffix.isEmpty ? "" : "." + suffix)
                let path = try RemotePath.child(RemotePath.parent(current.path), conflictName)
                try await client.upload(contents, to: path)
                _ = try await refresh(current.parentID, catalog: catalog, client: client)
                return try await catalog.update(id, remote: remote)
            }
            if let filename, filename != current.remote.name {
                try await client.rename(current.path, to: filename)
                try await catalog.relocate(id, parentID: current.parentID, name: filename)
                current = try await catalog.record(id)
            }
            if let parentID, parentID != current.parentID {
                let parent = try await catalog.record(parentID)
                try await client.move(current.path, to: parent.path)
                try await catalog.relocate(id, parentID: parentID, name: current.remote.name)
                current = try await catalog.record(id)
            }
            if let contents { try await client.upload(contents, to: current.path) }
            let metadata = try await client.metadata(current.path)
            return try await catalog.update(id, remote: metadata)
        }
    }

    func delete(_ id: String, contentVersion: Data, recursive: Bool) async throws {
        try await serialized {
            let (catalog, client, _) = try prepare()
            let record = try await catalog.record(id)
            let remote = try await client.metadata(record.path)
            guard Data(remote.contentTag.utf8) == contentVersion || record.remote.isDirectory else {
                throw DriveError.conflict
            }
            if record.remote.isDirectory && !recursive {
                guard try await client.list(record.path).isEmpty else {
                    throw DriveError.message("The folder is not empty.")
                }
            }
            try await client.remove(record.path)
            try await catalog.remove(id)
        }
    }

    func pin(_ ids: [String], value: Bool) async throws {
        try await serialized {
            let (catalog, _, _) = try prepare()
            var selected: [FileRecord] = []
            for id in ids { selected.append(try await catalog.record(id)) }
            for record in selected.sorted(by: { $0.path.count < $1.path.count }) {
                try await catalog.setPinned(record.id, value, clearingDescendants: true)
            }
        }
    }
}
