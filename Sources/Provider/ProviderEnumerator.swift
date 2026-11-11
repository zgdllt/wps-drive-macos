import Foundation
import FileProvider

final class ProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let store: ProviderStore
    private let parentID: String?
    private var tasks: [Task<Void, Never>] = []
    private let lock = NSLock()
    private var lastAnchor: Int64?

    init(store: ProviderStore, identifier: NSFileProviderItemIdentifier) {
        self.store = store
        self.parentID = identifier == .workingSet ? nil : coreID(identifier)
    }

    func invalidate() {
        lock.lock()
        let pending = tasks
        tasks.removeAll()
        lock.unlock()
        pending.forEach { $0.cancel() }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let task = Task {
            do {
                let (items, anchor) = try await store.snapshot(parentID)
                remember(anchor)
                try Task.checkCancellation()
                observer.didEnumerate(items.map(ProviderItem.init))
                observer.finishEnumerating(upTo: nil)
            } catch { observer.finishEnumeratingWithError(providerError(error)) }
        }
        track(task)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let task = Task {
            guard let revision = Int64(String(decoding: anchor.rawValue, as: UTF8.self)) else {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            do {
                let (updated, deleted, revision) = try await store.changes(since: revision, parentID: parentID)
                remember(revision)
                try Task.checkCancellation()
                observer.didUpdate(updated.map(ProviderItem.init))
                observer.didDeleteItems(withIdentifiers: deleted.map(providerID))
                observer.finishEnumeratingChanges(upTo: Self.anchor(revision), moreComing: false)
            } catch { observer.finishEnumeratingWithError(providerError(error)) }
        }
        track(task)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        lock.lock()
        let anchor = lastAnchor
        lock.unlock()
        if let anchor { completionHandler(Self.anchor(anchor)); return }
        let task = Task {
            let revision = try? await store.revision()
            completionHandler(revision.map(Self.anchor))
        }
        track(task)
    }

    private static func anchor(_ revision: Int64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(revision).utf8))
    }

    private func remember(_ anchor: Int64) {
        lock.lock()
        lastAnchor = anchor
        lock.unlock()
    }

    private func track(_ task: Task<Void, Never>) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }
}
