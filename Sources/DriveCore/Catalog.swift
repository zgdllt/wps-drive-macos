import Foundation

public struct FileRecord: Codable, Equatable {
    public var id: String
    public var parentID: String
    public var path: String
    public var remote: RemoteEntry
    public var pinned: Bool?

    public var metadataTag: String {
        "\(parentID)|\(remote.name)|\(remote.modified)|\(String(describing: pinned))"
    }
}

public struct CatalogChange: Codable {
    public var revision: Int64
    public var id: String
    public var oldParent: String
    public var newParent: String?
}

private struct CatalogData: Codable {
    var revision: Int64 = 0
    var records: [String: FileRecord] = [
        "root": FileRecord(id: "root", parentID: "root", path: "/",
                           remote: RemoteEntry(name: "WPS", size: 0, isDirectory: true))
    ]
    var changes: [CatalogChange] = []
    var visited: Set<String> = []
}

public actor Catalog {
    private let file: URL
    private var data: CatalogData

    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            data = try JSONDecoder().decode(CatalogData.self, from: Data(contentsOf: file))
        } else {
            data = CatalogData()
        }
    }

    public func record(_ id: String) throws -> FileRecord {
        guard let record = data.records[id] else { throw DriveError.missing }
        return record
    }

    public func revision() -> Int64 { data.revision }
    public func all() -> [FileRecord] { Array(data.records.values).filter { $0.id != "root" } }
    public func visited() -> [FileRecord] { data.visited.compactMap { data.records[$0] } }
    public func children(_ id: String) -> [FileRecord] {
        data.records.values.filter { $0.id != "root" && $0.parentID == id }
            .sorted { $0.remote.name < $1.remote.name }
    }

    public func reconcile(_ parentID: String, entries: [RemoteEntry]) throws -> [FileRecord] {
        let parent = try record(parentID)
        let previous = children(parentID)
        var seen = Set<String>()
        for entry in entries {
            let path = try RemotePath.child(parent.path, entry.name)
            var item = previous.first { $0.path == path } ??
                FileRecord(id: UUID().uuidString, parentID: parentID, path: path, remote: entry)
            item.remote = entry
            seen.insert(item.id)
            if data.records[item.id] != item {
                append(item.id, oldParent: item.parentID, newParent: item.parentID)
                data.records[item.id] = item
            }
        }
        for item in previous where !seen.contains(item.id) { removeTree(item.id) }
        data.visited.insert(parentID)
        try save()
        return children(parentID)
    }

    public func relocate(_ id: String, parentID: String, name: String) throws {
        var item = try record(id)
        let parent = try record(parentID)
        let oldPath = item.path
        let newPath = try RemotePath.child(parent.path, name)
        let oldParent = item.parentID
        item.path = newPath
        item.parentID = parentID
        item.remote.name = name
        data.records[id] = item
        append(id, oldParent: oldParent, newParent: parentID)
        for var descendant in Array(data.records.values) where descendant.path.hasPrefix(oldPath + "/") {
            descendant.path = newPath + descendant.path.dropFirst(oldPath.count)
            data.records[descendant.id] = descendant
            append(descendant.id, oldParent: descendant.parentID, newParent: descendant.parentID)
        }
        try save()
    }

    public func setPinned(_ id: String, _ pinned: Bool, clearingDescendants: Bool = false) throws {
        var item = try record(id)
        if clearingDescendants && item.remote.isDirectory {
            for var descendant in Array(data.records.values)
                where descendant.path.hasPrefix(item.path + "/") && descendant.pinned != nil {
                descendant.pinned = nil
                data.records[descendant.id] = descendant
                append(descendant.id, oldParent: descendant.parentID, newParent: descendant.parentID)
            }
        }
        item.pinned = pinned
        data.records[id] = item
        append(id, oldParent: item.parentID, newParent: item.parentID)
        try save()
    }

    public func update(_ id: String, remote: RemoteEntry) throws -> FileRecord {
        var item = try record(id)
        item.remote = remote
        if data.records[id] != item {
            data.records[id] = item
            append(id, oldParent: item.parentID, newParent: item.parentID)
            try save()
        }
        return item
    }

    public func remove(_ id: String) throws {
        removeTree(id)
        try save()
    }

    public func changes(since anchor: Int64, parentID: String?) throws -> ([FileRecord], [String], Int64) {
        guard anchor >= 0, anchor <= data.revision else {
            throw DriveError.invalidAnchor
        }
        var updates = Set<String>()
        var deletes = Set<String>()
        for change in data.changes where change.revision > anchor {
            if let parentID {
                if change.oldParent == parentID && change.newParent != parentID {
                    deletes.insert(change.id)
                    updates.remove(change.id)
                } else if change.newParent == parentID {
                    updates.insert(change.id)
                    deletes.remove(change.id)
                }
            } else if change.newParent == nil {
                deletes.insert(change.id)
                updates.remove(change.id)
            } else {
                updates.insert(change.id)
                deletes.remove(change.id)
            }
        }
        return (updates.compactMap { data.records[$0] }, Array(deletes), data.revision)
    }

    private func append(_ id: String, oldParent: String, newParent: String?) {
        data.revision += 1
        data.changes.append(CatalogChange(
            revision: data.revision, id: id, oldParent: oldParent, newParent: newParent
        ))
    }

    private func removeTree(_ id: String) {
        for child in children(id) { removeTree(child.id) }
        guard let record = data.records.removeValue(forKey: id) else { return }
        data.visited.remove(id)
        append(id, oldParent: record.parentID, newParent: nil)
    }

    private func save() throws {
        try JSONEncoder().encode(data).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
