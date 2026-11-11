import Foundation
import FileProvider
import UniformTypeIdentifiers

final class ProbeProvider: NSObject, NSFileProviderReplicatedExtension {
    private let manager: NSFileProviderManager?

    required init(domain: NSFileProviderDomain) {
        manager = NSFileProviderManager(for: domain)
        super.init()
        NSLog("WPS_NATIVE_PROBE: extension initialized without App Group")
    }

    func invalidate() {}

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        if identifier == .rootContainer || identifier.rawValue == "probe" {
            completionHandler(ProbeItem(root: identifier == .rootContainer), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress(totalUnitCount: 0)
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        do {
            guard itemIdentifier.rawValue == "probe" else { throw NSFileProviderError(.noSuchItem) }
            guard let manager else { throw NSFileProviderError(.serverUnreachable) }
            let file = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
            try Data(repeating: 0x57, count: 256 * 1024).write(to: file)
            completionHandler(file, ProbeItem(root: false), nil)
        } catch { completionHandler(nil, nil, error) }
        return Progress(totalUnitCount: 0)
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        guard containerItemIdentifier == .rootContainer || containerItemIdentifier == .workingSet else {
            throw NSFileProviderError(.noSuchItem)
        }
        return ProbeEnumerator()
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
        contents: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, fields, false, CocoaError(.fileWriteNoPermission))
        return Progress(totalUnitCount: 0)
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents: URL?,
        options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, changedFields, false, CocoaError(.fileWriteNoPermission))
        return Progress(totalUnitCount: 0)
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(CocoaError(.fileWriteNoPermission))
        return Progress(totalUnitCount: 0)
    }
}

private final class ProbeItem: NSObject, NSFileProviderItem {
    let root: Bool
    init(root: Bool) { self.root = root }
    var itemIdentifier: NSFileProviderItemIdentifier { root ? .rootContainer : .init("probe") }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { root ? "WPS Native Probe" : "probe.txt" }
    var contentType: UTType { root ? .folder : .plainText }
    var documentSize: NSNumber? { root ? nil : NSNumber(value: 256 * 1024) }
    var capabilities: NSFileProviderItemCapabilities {
        root ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
    }
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }
    var itemVersion: NSFileProviderItemVersion {
        .init(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

private final class ProbeEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.didEnumerate([ProbeItem(root: false)])
        observer.finishEnumerating(upTo: nil)
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data("1".utf8)), moreComing: false)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("1".utf8)))
    }
}
