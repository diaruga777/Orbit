import Foundation
import IrohLib
import OrbitWire
import OrbitCore

/// The iroh byte-stream primitive used by dumbpipe. Orbit uses its own ALPN
/// and pinned endpoint keys; the desktop CLI's default handshake is not used.
public actor OrbitDumbpipe {
    public static let shared = OrbitDumbpipe()
    public static let alpn = Data("orbit/direct/1".utf8)
    private var endpoint: Endpoint?
    private var lastDirectAddress: [DeviceID: String] = [:]
    private var dialBackoff: [DeviceID: ContinuousClock.Instant] = [:]
    private var binding: Task<Endpoint, Error>?
    public init() {}
    public func start(secretURL: URL? = nil) async throws -> DeviceID {
        if let endpoint { return try DeviceID(bytes: endpoint.id().toBytes()) }
        if binding == nil {
            binding = Task {
                let secret: Data
                if let secretURL {
                    if FileManager.default.fileExists(atPath: secretURL.path) { secret = try Data(contentsOf: secretURL) }
                    else {
                        secret = SecretKey.generate().toBytes()
                        try FileManager.default.createDirectory(at: secretURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try secret.write(to: secretURL, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
                    }
                } else { secret = SecretKey.generate().toBytes() }
                // This runs only after the user chooses dumbpipe. N0 enables
                // iroh's discovery and relay services; local-only never calls it.
                return try await Endpoint.bind(options: EndpointOptions(preset: presetN0(), secretKey: secret, alpns: [Self.alpn]))
            }
        }
        do { endpoint = try await binding!.value; binding = nil; return try DeviceID(bytes: endpoint!.id().toBytes()) }
        catch { binding = nil; throw error }
    }
    public func stop() async throws {
        let current = endpoint
        endpoint = nil
        lastDirectAddress.removeAll()
        dialBackoff.removeAll()
        try await current?.close()
    }
    public func relayURL(for id: DeviceID) -> String? {
        guard let endpoint, endpoint.id().toBytes() == id.bytes else { return nil }
        return OrbitPairingCode.validRelay(endpoint.addr().relayUrl())
    }
    public func dial(endpoint id: String, expecting expected: DeviceID, relay: String? = nil) async throws -> any BEPByteStream {
        _ = try await start()
        guard let endpoint else { throw CancellationError() }
        let clock = ContinuousClock()
        if let retry = dialBackoff[expected], clock.now < retry { throw IrohDirectConnection.Unavailable() }
        do {
            let stream = try await Self.dial(from: endpoint, to: id, expecting: expected, relay: relay,
                                             directAddress: lastDirectAddress[expected])
            lastDirectAddress[expected] = stream.directAddress
            dialBackoff.removeValue(forKey: expected)
            return stream
        } catch {
            if !Task.isCancelled { dialBackoff[expected] = clock.now + .seconds(10) }
            throw error
        }
    }

    static func dial(from endpoint: Endpoint, to id: String, expecting expected: DeviceID,
                     relay: String?, directAddress: String? = nil) async throws -> OrbitIrohStream {
        let remote = try EndpointId.fromString(s: id)
        guard remote.toBytes() == expected.bytes else { throw CodeFailure("The dumbpipe endpoint does not match the paired Mac.") }
        let hint = OrbitPairingCode.validRelay(relay)
        var connection: Connection? = nil
        if let directAddress {
            connection = try? await IrohDirectConnection.connect(from: endpoint,
                to: EndpointAddr(id: remote, relayUrl: nil, addresses: [directAddress]), alpn: alpn,
                timeout: .milliseconds(700))
        }
        if connection == nil, let hint {
            try Task.checkCancellation()
            connection = try? await IrohDirectConnection.connect(from: endpoint,
                to: EndpointAddr(id: remote, relayUrl: hint, addresses: []), alpn: alpn)
        }
        if connection == nil {
            try Task.checkCancellation()
            connection = try await IrohDirectConnection.connect(from: endpoint,
                to: EndpointAddr(id: remote, relayUrl: nil, addresses: []), alpn: alpn)
        }
        guard let connection else { throw IrohDirectConnection.Unavailable() }
        do {
            try Task.checkCancellation()
            return OrbitIrohStream(connection: connection, stream: try await connection.openBi())
        } catch {
            try? connection.close(errorCode: 0, reason: Data())
            throw error
        }
    }
    public func accept(_ handler: @escaping @Sendable (OrbitAcceptedPeer) async -> Void) async throws {
        guard let endpoint else { throw CodeFailure("Start dumbpipe before accepting peers.") }
        while let incoming = await endpoint.acceptNext() {
            Task {
                do {
                    let accepting = try await incoming.accept()
                    guard try await accepting.alpn() == Self.alpn else { return }
                    let connection = try await accepting.connect()
                    try await IrohDirectConnection.awaitDirect(connection)
                    let peer = try DeviceID(bytes: connection.remoteId().toBytes())
                    let stream = OrbitIrohStream(connection: connection, stream: try await connection.acceptBi())
                    await handler(OrbitAcceptedPeer(stream: stream, device: peer, remoteDescription: "dumbpipe"))
                } catch { }
            }
        }
    }
}
final class OrbitIrohStream: BEPByteStream, @unchecked Sendable {
    private let connection: Connection
    private let stream: BiStream
    private let reader: OrbitIrohReader
    private let watch: Task<Void, Never>
    var directAddress: String? { connection.paths().first { $0.isSelected && $0.isIp }?.remoteAddr }
    init(connection: Connection, stream: BiStream) {
        self.connection = connection
        self.stream = stream
        watch = IrohDirectConnection.stopOnPathLoss(connection)
        reader = OrbitIrohReader(recv: stream.recv())
    }
    func read(exactly count: Int) async throws -> Data { try await reader.read(count) }
    func write(_ data: Data) async throws { try await stream.send().writeAll(buf: data) }
    deinit { close() }
    func close() {
        watch.cancel()
        try? connection.close(errorCode: 0, reason: Data())
    }
}
private actor OrbitIrohReader {
    let recv: RecvStream
    init(recv: RecvStream) { self.recv = recv }
    func read(_ count: Int) async throws -> Data {
        guard (0...CodeWire.maxPayloadBytes).contains(count) else { throw CodeFailure("Invalid stream read.") }
        var result = Data()
        while result.count < count {
            let bytes = try await recv.read(sizeLimit: UInt32(min(count - result.count, 65536)))
            guard !bytes.isEmpty else { throw BEPStreamError.closed }
            result.append(bytes)
        }
        return result
    }
}
