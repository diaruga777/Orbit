import Foundation

/// The native archive allows only handshake and QUIC control frames on relay
/// paths. This check bounds fallback latency and closes interrupted transfers.
public enum IrohDirectConnection {
    public struct Unavailable: LocalizedError, Sendable {
        public init() {}
        public var errorDescription: String? { "Couldn’t connect directly to the Mac." }
    }

    public static func connect(from endpoint: Endpoint, to address: EndpointAddr,
                               alpn: Data, timeout: Duration = .seconds(5)) async throws -> Connection {
        try await within(timeout) {
            let connection = try await endpoint.connect(addr: address, alpn: alpn)
            do {
                try await awaitDirect(connection)
                return connection
            } catch {
                try? connection.close(errorCode: 0, reason: Data())
                throw error
            }
        }
    }

    public static func awaitDirect(_ connection: Connection) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(4)
        while !isDirect(connection.paths()) {
            guard clock.now < deadline, connection.closeReason() == nil else { throw Unavailable() }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
    }

    public static func stopOnPathLoss(_ connection: Connection) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled, connection.closeReason() == nil {
                guard isDirect(connection.paths()) else {
                    try? connection.close(errorCode: 1, reason: Data())
                    return
                }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }
    }

    private static func isDirect(_ paths: [PathSnapshot]) -> Bool {
        paths.contains { $0.isSelected && $0.isIp }
    }

    public static func within<T: Sendable>(_ duration: Duration,
                                           _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: duration)
                throw Unavailable()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
