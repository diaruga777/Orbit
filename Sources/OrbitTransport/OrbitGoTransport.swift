import Foundation
import OrbitWire
import COrbitNet

#if canImport(Darwin)
import Darwin
#endif

public typealias OrbitNet = OrbitGoTransport

/// The small C ABI exported by the `orbitnet` Go package.  The functions are
/// looked up at runtime so the Swift package remains buildable with the
/// checked-in archive; `scripts/build_libtailscale.sh` adds the symbols to a
/// rebuilt archive.  This also makes the transport straightforward to fake in
/// unit tests without opening a socket.
public final class OrbitGoTransport: OrbitPeerDialing, OrbitPeerLookup, OrbitPeerAnnouncing, @unchecked Sendable {
    public struct Configuration: Sendable {
        public let stateDirectory: URL
        public let requestLocalNetworkAccess: Bool
        public let tailnetHandle: (@Sendable () async throws -> Int32)?

        public init(stateDirectory: URL, requestLocalNetworkAccess: Bool = false,
                    tailnetHandle: (@Sendable () async throws -> Int32)? = nil) {
            self.stateDirectory = stateDirectory
            self.requestLocalNetworkAccess = requestLocalNetworkAccess
            self.tailnetHandle = tailnetHandle
        }
    }

    private let configuration: Configuration
    private let api: OrbitGoAPI

    public init(configuration: Configuration, api: OrbitGoAPI = .load()) {
        self.configuration = configuration
        self.api = api
    }

    public func identity() throws -> DeviceID {
        // All three apps can launch at once against the same App Group. Go’s
        // in-process lock cannot protect certificate creation across processes.
        try FileManager.default.createDirectory(at: configuration.stateDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lockPath = configuration.stateDirectory.appendingPathComponent("identity.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw BEPStreamError.posix(errno) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw BEPStreamError.posix(errno) }
        defer { flock(descriptor, LOCK_UN) }
        var buffer = [CChar](repeating: 0, count: 128)
        let result = configuration.stateDirectory.path.withCString { path in
            api.identity(path, &buffer, buffer.count)
        }
        try check(result, operation: "identity")
        return try DeviceID(string: String(cString: buffer))
    }

    public func dial(_ address: OrbitPeerAddress, expecting expected: DeviceID) async throws -> any BEPByteStream {
        if case .dumbpipe(let endpoint) = address { return try await OrbitDumbpipe.shared.dial(endpoint: endpoint, expecting: expected) }
        if configuration.requestLocalNetworkAccess, case .tcp(let host, let port) = address {
            try await OrbitLocalNetworkAccess(host: host, port: port).check()
        }
        let handle = try await configuration.tailnetHandle?() ?? 0
        var descriptor: Int32 = -1
        let result = configuration.stateDirectory.path.withCString { directory in
            address.description.withCString { address in
                expected.description.withCString { peer in
                    api.dial(directory, address, peer, handle, &descriptor)
                }
            }
        }
        try check(result, operation: "dial")
        return FileDescriptorByteStream(fileDescriptor: descriptor)
    }

    public func lookup(_ device: DeviceID) async throws -> OrbitDiscoveryResult {
        var buffer = [CChar](repeating: 0, count: 64 * 1024)
        var retryAfter: Int32 = 0
        let result = device.description.withCString { id in
            api.lookup(id, &buffer, buffer.count, &retryAfter)
        }
        if result != 0 {
            throw mapError(result, operation: "lookup", retryAfter: retryAfter)
        }
        let data = Data(buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
        struct Response: Decodable {
            var seen: Date?
            var addresses: [String]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(Response.self, from: data)
        let addresses = response.addresses.compactMap(OrbitPeerAddress.init(syncthingURL:))
        return OrbitDiscoveryResult(addresses: addresses, seen: response.seen)
    }

    public func announce(addresses: [String]) async throws -> TimeInterval {
        let payload = try JSONSerialization.data(withJSONObject: ["addresses": addresses])
        var seconds: Int32 = 0
        let result = configuration.stateDirectory.path.withCString { directory in
            String(decoding: payload, as: UTF8.self).withCString { pointer in
                api.announce(directory, pointer, &seconds)
            }
        }
        try check(result, operation: "announce")
        return TimeInterval(max(0, seconds))
    }

    public func listen(bindAddress: String) async throws -> OrbitGoListener {
        let handle = try await configuration.tailnetHandle?() ?? 0
        var listener: Int32 = 0
        let result = configuration.stateDirectory.path.withCString { directory in
            bindAddress.withCString { address in
                api.listen(directory, address, handle, &listener)
            }
        }
        try check(result, operation: "listen")
        return OrbitGoListener(handle: listener, api: api)
    }

    public func relayListener(url: URL) async throws -> OrbitGoListener {
        var listener: Int32 = 0
        let result = configuration.stateDirectory.path.withCString { directory in
            url.absoluteString.withCString { relay in
                api.relayJoin(directory, relay, &listener)
            }
        }
        try check(result, operation: "relay join")
        return OrbitGoListener(handle: listener, api: api)
    }

    public func pickRelay() throws -> URL {
        var buffer = [CChar](repeating: 0, count: 1024)
        try check(api.relayPick(&buffer, buffer.count), operation: "relay selection")
        guard let url = URL(string: String(cString: buffer)) else {
            throw OrbitTransportError.internalError("relay returned an invalid URL")
        }
        return url
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result != 0 else { return }
        throw mapError(result, operation: operation, retryAfter: 0)
    }

    private func mapError(_ result: Int32, operation: String, retryAfter: Int32) -> OrbitTransportError {
        switch result {
        case -3: return .internalError("\(operation): identity unavailable")
        case -4: return .unreachable(api.message())
        case -5: return .handshakeFailed(api.message())
        case -6: return .identityMismatch(expected: "requested", actual: api.message())
        case -7: return .unreachable(api.message())
        case -10, -11: return .internalError("\(operation): listener closed")
        case let value where value <= -1000:
            return .lookupFailed(status: Int(-value - 1000), retryAfter: retryAfter > 0 ? TimeInterval(retryAfter) : nil)
        default: return .internalError("\(operation): \(api.message())")
        }
    }
}

public final class OrbitGoListener: OrbitPeerListening, @unchecked Sendable {
    private let handle: Int32
    private let api: OrbitGoAPI
    private let lock = NSLock()
    private var closed = false

    fileprivate init(handle: Int32, api: OrbitGoAPI) {
        self.handle = handle
        self.api = api
    }

    public func accept() async throws -> OrbitAcceptedPeer {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    var descriptor: Int32 = -1
                    var deviceBuffer = [CChar](repeating: 0, count: 128)
                    var remoteBuffer = [CChar](repeating: 0, count: 512)
                    let result = api.accept(handle, &descriptor, &deviceBuffer, deviceBuffer.count,
                                            &remoteBuffer, remoteBuffer.count)
                    guard result == 0 else { throw OrbitTransportError.internalError(api.message()) }
                    let stream = FileDescriptorByteStream(fileDescriptor: descriptor)
                    do {
                        let device = try DeviceID(string: String(cString: deviceBuffer))
                        continuation.resume(returning: OrbitAcceptedPeer(stream: stream, device: device,
                            remoteDescription: String(cString: remoteBuffer)))
                    } catch { stream.close(); throw error }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public var announcedAddresses: [String] {
        get async {
            var buffer = [CChar](repeating: 0, count: 4096)
            guard api.listenerAddresses(handle, &buffer, buffer.count) == 0 else { return [] }
            let data = Data(buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
    }

    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        _ = api.closeListener(handle)
    }

    deinit { close() }
}

/// A C-call-compatible function table. Tests can inject a table; production
/// uses `dlsym` against the libtailscale image that contains orbitnet.
public struct OrbitGoAPI: @unchecked Sendable {
    public typealias Errmsg = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int32
    public typealias Identity = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int32
    public typealias Dial = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<Int32>?) -> Int32
    public typealias Lookup = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int32>?) -> Int32
    public typealias Announce = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> Int32
    public typealias Listen = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<Int32>?) -> Int32
    public typealias RelayJoin = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> Int32
    public typealias RelayPick = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int32
    public typealias Accept = @convention(c) (Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, Int) -> Int32
    public typealias ListenerAddresses = @convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int32
    public typealias CloseListener = @convention(c) (Int32) -> Int32

    let errmsg: Errmsg
    let identity: Identity
    let dial: Dial
    let lookup: Lookup
    let announce: Announce
    let listen: Listen
    let relayJoin: RelayJoin
    let relayPick: RelayPick
    let accept: Accept
    let listenerAddresses: ListenerAddresses
    let closeListener: CloseListener

    public init(errmsg: @escaping Errmsg, identity: @escaping Identity, dial: @escaping Dial,
                lookup: @escaping Lookup, announce: @escaping Announce, listen: @escaping Listen,
                relayJoin: @escaping RelayJoin, relayPick: @escaping RelayPick,
                accept: @escaping Accept, listenerAddresses: @escaping ListenerAddresses,
                closeListener: @escaping CloseListener) {
        self.errmsg = errmsg; self.identity = identity; self.dial = dial; self.lookup = lookup
        self.announce = announce; self.listen = listen; self.relayJoin = relayJoin
        self.relayPick = relayPick; self.accept = accept; self.listenerAddresses = listenerAddresses
        self.closeListener = closeListener
    }

    public static func load() -> OrbitGoAPI {
        let errmsg: Errmsg = orbitnet_errmsg
        let identity: Identity = orbitnet_identity
        let dial: Dial = orbitnet_dial
        let lookup: Lookup = orbitnet_lookup
        let announce: Announce = orbitnet_announce
        let listen: Listen = orbitnet_listen
        let relayJoin: RelayJoin = orbitnet_relay_join
        let relayPick: RelayPick = orbitnet_relay_pick
        let accept: Accept = orbitnet_accept
        let listenerAddresses: ListenerAddresses = orbitnet_listener_addresses
        let closeListener: CloseListener = orbitnet_close_listener
        return OrbitGoAPI(errmsg: errmsg, identity: identity, dial: dial, lookup: lookup,
                              announce: announce, listen: listen, relayJoin: relayJoin,
                              relayPick: relayPick, accept: accept,
                              listenerAddresses: listenerAddresses, closeListener: closeListener)
    }

    public static let unavailable = OrbitGoAPI(
        errmsg: { _, _ in 0 },
        identity: { _, _, _ in -1 }, dial: { _, _, _, _, _ in -1 },
        lookup: { _, _, _, _ in -1 }, announce: { _, _, _ in -1 }, listen: { _, _, _, _ in -1 },
        relayJoin: { _, _, _ in -1 }, relayPick: { _, _ in -1 },
        accept: { _, _, _, _, _, _ in -1 }, listenerAddresses: { _, _, _ in -1 },
        closeListener: { _ in 0 })

    func message() -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        _ = errmsg(&buffer, buffer.count)
        return String(cString: buffer)
    }
}
