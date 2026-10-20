import Foundation
import IrohLib
import OrbitWire
import OrbitCore

/// The iroh byte-stream primitive used by dumbpipe. Orbit uses its own ALPN
/// and pinned endpoint keys; the desktop CLI's default handshake is not used.
public actor OrbitDumbpipe {
    public static let shared = OrbitDumbpipe()
    public static let alpn = Data("orbit/1".utf8)
    private var endpoint: Endpoint?
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
    public func dial(endpoint id: String, expecting expected: DeviceID) async throws -> any BEPByteStream {
        _ = try await start()
        let remote = try EndpointId.fromString(s: id)
        guard remote.toBytes() == expected.bytes else { throw CodeFailure("The dumbpipe endpoint does not match the paired Mac.") }
        let connection = try await endpoint!.connect(addr: EndpointAddr(id: remote, relayUrl: nil, addresses: []), alpn: Self.alpn)
        return OrbitIrohStream(connection: connection, stream: try await connection.openBi())
    }
    public func accept(_ handler: @escaping @Sendable (OrbitAcceptedPeer) async -> Void) async throws {
        guard let endpoint else { throw CodeFailure("Start dumbpipe before accepting peers.") }
        while let incoming = await endpoint.acceptNext() {
            Task {
                do {
                    let accepting = try await incoming.accept()
                    guard try await accepting.alpn() == Self.alpn else { return }
                    let connection = try await accepting.connect()
                    let peer = try DeviceID(bytes: connection.remoteId().toBytes())
                    let stream = OrbitIrohStream(connection: connection, stream: try await connection.acceptBi())
                    await handler(OrbitAcceptedPeer(stream: stream, device: peer, remoteDescription: "dumbpipe"))
                } catch { }
            }
        }
    }
}
private final class OrbitIrohStream: BEPByteStream, @unchecked Sendable {
    private let connection: Connection
    private let stream: BiStream
    private let reader: OrbitIrohReader
    init(connection: Connection, stream: BiStream) { self.connection = connection; self.stream = stream; reader = OrbitIrohReader(recv: stream.recv()) }
    func read(exactly count: Int) async throws -> Data { try await reader.read(count) }
    func write(_ data: Data) async throws { try await stream.send().writeAll(buf: data) }
    func close() { try? connection.close(errorCode: 0, reason: Data()) }
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
