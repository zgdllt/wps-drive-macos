import Foundation
import FileProvider

final class ProviderSession {
    private let connection: NSXPCConnection

    private init(connection: NSXPCConnection) { self.connection = connection }
    deinit { connection.invalidate() }

    static func connect(_ manager: NSFileProviderManager) async throws -> ProviderSession {
        let service: NSFileProviderService = try await withCheckedThrowingContinuation { continuation in
            manager.getService(named: .init(ProviderControlService.name), for: .rootContainer) {
                if let service = $0 { continuation.resume(returning: service) }
                else { continuation.resume(throwing: $1 ?? DriveError.unavailable) }
            }
        }
        let connection: NSXPCConnection = try await withCheckedThrowingContinuation { continuation in
            service.getFileProviderConnection {
                if let connection = $0 { continuation.resume(returning: connection) }
                else { continuation.resume(throwing: $1 ?? DriveError.unavailable) }
            }
        }
        connection.remoteObjectInterface = NSXPCInterface(with: ProviderControl.self)
        connection.resume()
        return ProviderSession(connection: connection)
    }

    func configure(_ configuration: DriveConnection) async throws {
        let data = try JSONEncoder().encode(configuration)
        try await call { $0.configure(data, reply: $1) }
    }

    func setPinned(_ identifiers: [String], value: Bool) async throws {
        try await call { $0.setPinned(identifiers, value: value, reply: $1) }
    }

    func release(_ identifiers: [String]) async throws {
        try await call { $0.release(identifiers, reply: $1) }
    }

    private func call(_ operation: (ProviderControl, @escaping (NSError?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let object = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) }
            guard let proxy = object as? ProviderControl else {
                continuation.resume(throwing: DriveError.unavailable)
                return
            }
            operation(proxy) {
                if let error = $0 { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
