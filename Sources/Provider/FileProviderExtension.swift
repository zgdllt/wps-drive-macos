import Foundation
import FileProvider
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction, NSFileProviderServicing {
    private let domain: NSFileProviderDomain
    private let store: ProviderStore
    private let manager: NSFileProviderManager?
    private let control: ProviderControlSource
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let store = ProviderStore(domain: domain.identifier.rawValue)
        let manager = NSFileProviderManager(for: domain)
        self.store = store
        self.manager = manager
        self.control = ProviderControlSource(store: store, manager: manager)
        super.init()
    }
    func invalidate() { control.invalidate() }

    func supportedServiceSources(
        for itemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void
    ) -> Progress {
        completionHandler(itemIdentifier == .rootContainer ? [control] : [], nil)
        return Progress(totalUnitCount: 0)
    }

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        operation { [self] in
            do { completionHandler(ProviderItem(try await store.record(coreID(identifier))), nil) }
            catch { completionHandler(nil, providerError(error)) }
        }
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        operation { [self] in
            do {
                let directory = try manager?.temporaryDirectoryURL() ?? FileManager.default.temporaryDirectory
                let (file, record) = try await store.download(coreID(itemIdentifier), directory: directory)
                completionHandler(file, ProviderItem(record), nil)
            } catch { completionHandler(nil, nil, providerError(error)) }
        }
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
        contents: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        operation { [self] in
            do {
                let record = try await store.create(
                    name: itemTemplate.filename, parentID: coreID(itemTemplate.parentItemIdentifier),
                    directory: itemTemplate.contentType == .folder, contents: contents
                )
                signal()
                completionHandler(ProviderItem(record), [], false, nil)
            } catch { completionHandler(nil, fields, false, providerError(error)) }
        }
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents: URL?,
        options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        operation { [self] in
            do {
                var strictConflict = false
                if #available(macOS 26.0, *) { strictConflict = options.contains(.failOnConflict) }
                let record = try await store.modify(
                    id: coreID(item.itemIdentifier), contentVersion: baseVersion.contentVersion,
                    filename: changedFields.contains(.filename) ? item.filename : nil,
                    parentID: changedFields.contains(.parentItemIdentifier) ? coreID(item.parentItemIdentifier) : nil,
                    contents: changedFields.contains(.contents) ? contents : nil,
                    failOnConflict: strictConflict
                )
                signal()
                completionHandler(ProviderItem(record), [], false, nil)
            } catch { completionHandler(nil, changedFields, false, providerError(error)) }
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        operation { [self] in
            do {
                try await store.delete(
                    coreID(identifier), contentVersion: baseVersion.contentVersion,
                    recursive: options.contains(.recursive)
                )
                signal()
                completionHandler(nil)
            } catch { completionHandler(providerError(error)) }
        }
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer {
            throw NSFileProviderError(.noSuchItem)
        }
        return ProviderEnumerator(store: store, identifier: containerItemIdentifier)
    }

    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        operation { [self] in
            do {
                switch actionIdentifier.rawValue {
                case "io.github.zgdllt.WPSDrive.pin":
                    try await control.updatePinned(itemIdentifiers.map(coreID), value: true)
                case "io.github.zgdllt.WPSDrive.unpin":
                    try await control.releaseItems(itemIdentifiers.map(coreID))
                default:
                    throw DriveError.unavailable
                }
                completionHandler(nil)
            } catch { completionHandler(providerError(error)) }
        }
    }

    private func signal() {
        manager?.signalEnumerator(for: .workingSet) { _ in }
    }

    private func operation(_ body: @escaping () async -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            await body()
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
