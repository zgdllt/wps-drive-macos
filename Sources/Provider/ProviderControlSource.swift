import Foundation
import FileProvider

final class ProviderControlSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, ProviderControl {
    private let store: ProviderStore
    private let manager: NSFileProviderManager?
    private let listener = NSXPCListener.anonymous()

    init(store: ProviderStore, manager: NSFileProviderManager?) {
        self.store = store
        self.manager = manager
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var serviceName: NSFileProviderServiceName { .init(ProviderControlService.name) }
    var isRestricted: Bool { true }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint { listener.endpoint }
    func invalidate() { listener.invalidate() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ProviderControl.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func configure(_ data: Data, reply: @escaping (NSError?) -> Void) {
        Task {
            do {
                let connection = try JSONDecoder().decode(DriveConnection.self, from: data)
                guard connection.endpoint.scheme == "http", connection.endpoint.host == "127.0.0.1",
                      connection.endpoint.port != nil else { throw DriveError.unavailable }
                try await store.configure(connection)
                manager?.signalErrorResolved(NSFileProviderError(.notAuthenticated)) { _ in }
                manager?.signalErrorResolved(NSFileProviderError(.serverUnreachable)) { _ in }
                try await manager?.signalEnumerator(for: .rootContainer)
                try await manager?.signalEnumerator(for: .workingSet)
                reply(nil)
            } catch { reply(providerError(error) as NSError) }
        }
    }

    func setPinned(_ identifiers: [String], value: Bool, reply: @escaping (NSError?) -> Void) {
        Task {
            do {
                try await updatePinned(identifiers, value: value)
                reply(nil)
            } catch { reply(providerError(error) as NSError) }
        }
    }

    func release(_ identifiers: [String], reply: @escaping (NSError?) -> Void) {
        Task {
            do {
                try await releaseItems(identifiers)
                reply(nil)
            } catch { reply(providerError(error) as NSError) }
        }
    }

    func updatePinned(_ identifiers: [String], value: Bool) async throws {
        try await store.pin(identifiers, value: value)
        try await manager?.signalEnumerator(for: .workingSet)
    }

    func releaseItems(_ identifiers: [String]) async throws {
        guard let manager else { throw DriveError.unavailable }
        try await updatePinned(identifiers, value: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.waitForStabilization {
                if let error = $0 { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        for identifier in identifiers {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                manager.evictItem(identifier: providerID(identifier)) {
                    if let error = $0 { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }
}
