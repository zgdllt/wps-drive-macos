import Foundation
import FileProvider
import UniformTypeIdentifiers

func coreID(_ identifier: NSFileProviderItemIdentifier) -> String {
    identifier == .rootContainer ? "root" : identifier.rawValue
}

func providerID(_ identifier: String) -> NSFileProviderItemIdentifier {
    identifier == "root" ? .rootContainer : NSFileProviderItemIdentifier(identifier)
}

func providerError(_ error: Error) -> Error {
    if error is CancellationError { return CocoaError(.userCancelled) }
    if let drive = error as? DriveError {
        switch drive {
        case .authentication: return NSFileProviderError(.notAuthenticated)
        case .missing: return NSFileProviderError(.noSuchItem)
        case .conflict:
            if #available(macOS 26.0, *) {
                return NSFileProviderError(.localVersionConflictingWithServer)
            }
            return CocoaError(.fileWriteFileExists)
        case .collision: return NSFileProviderError(.filenameCollision)
        case .invalidAnchor: return NSFileProviderError(.syncAnchorExpired)
        case .unavailable: return NSFileProviderError(.serverUnreachable)
        case .message: break
        }
    }
    if error is URLError { return NSFileProviderError(.serverUnreachable) }
    return NSError(
        domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid,
        userInfo: [NSUnderlyingErrorKey: error, NSLocalizedDescriptionKey: error.localizedDescription]
    )
}

final class ProviderItem: NSObject, NSFileProviderItem {
    let record: FileRecord
    init(_ record: FileRecord) { self.record = record }

    var itemIdentifier: NSFileProviderItemIdentifier { providerID(record.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { providerID(record.parentID) }
    var filename: String { record.remote.name }
    var contentType: UTType {
        record.remote.isDirectory ? .folder : UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
    }
    var documentSize: NSNumber? { NSNumber(value: record.remote.size) }
    var capabilities: NSFileProviderItemCapabilities {
        if record.id == "root" { return [.allowsReading, .allowsContentEnumerating] }
        if record.remote.isDirectory {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems,
                    .allowsRenaming, .allowsReparenting, .allowsDeleting]
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting,
                .allowsDeleting]
    }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data(record.remote.contentTag.utf8),
                                  metadataVersion: Data(record.metadataTag.utf8))
    }
    var contentPolicy: NSFileProviderContentPolicy {
        if record.id == "root" { return .downloadLazily }
        guard let pinned = record.pinned else { return .inherited }
        return pinned ? .downloadEagerlyAndKeepDownloaded : .downloadLazily
    }
    var userInfo: [AnyHashable: Any]? { ["pinned": record.pinned == true] }
    var creationDate: Date? { Self.date(record.remote.created) }
    var contentModificationDate: Date? { Self.date(record.remote.modified) }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
