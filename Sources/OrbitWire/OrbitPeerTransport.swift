import Foundation

/// One way to reach a peer, as Syncthing writes addresses.
///
/// `tcp://host:port` and `relay://host:port/?id=…` come from discovery or
/// manual entry. `.tailscale` names a host on the embedded tailnet and is
/// dialed through the tsnet node rather than the system stack.
public enum OrbitPeerAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    case dumbpipe(endpoint: String)
    case tcp(host: String, port: UInt16)
    case relay(url: URL)
    case tailscale(host: String, port: UInt16)

    /// Parses a Syncthing address URL. Returns nil for schemes Orbit does not
    /// dial (`quic://`, `dynamic`, …).
    public init?(syncthingURL string: String) {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "dumbpipe":
            guard let id = url.host, id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { return nil }
            self = .dumbpipe(endpoint: id)
        case "tcp", "tcp4", "tcp6":
            guard let host = url.host, !host.isEmpty,
                  let port = UInt16(exactly: url.port ?? 22000), port > 0 else { return nil }
            self = .tcp(host: host, port: port)
        case "relay":
            guard url.host != nil else { return nil }
            self = .relay(url: url)
        default:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .dumbpipe(let endpoint): return "dumbpipe://" + endpoint
        case .tcp(let host, let port):
            return host.contains(":") ? "tcp://[\(host)]:\(port)" : "tcp://\(host):\(port)"
        case .relay(let url):
            return url.absoluteString
        case .tailscale(let host, let port):
            return host.contains(":") ? "tailscale://[\(host)]:\(port)" : "tailscale://\(host):\(port)"
        }
    }

    /// Relay addresses sort after direct ones; a LAN-looking address first.
    public var dialPriority: Int {
        switch self {
        case .tcp(let host, _): return OrbitPeerAddress.isPrivateHost(host) ? 0 : 1
        case .tailscale, .dumbpipe: return 0
        case .relay: return 2
        }
    }

    static func isPrivateHost(_ host: String) -> Bool {
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("fe80:") || host.hasPrefix("fd") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }
}

public enum OrbitTransportError: Error, Equatable, LocalizedError {
    case localNetworkDenied
    case unreachable(String)
    case identityMismatch(expected: String, actual: String)
    case handshakeFailed(String)
    case lookupFailed(status: Int, retryAfter: TimeInterval?)
    case notFound(retryAfter: TimeInterval?)
    case needsLogin
    case notSupported
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .localNetworkDenied:
            return "Local Network access is off for Orbit. Open iPhone Settings → Privacy & Security → Local Network, enable Orbit, then return and tap Pair this Mac."
        case .unreachable(let message): return message
        case .identityMismatch: return "The responding Mac does not match this pairing code. Copy a fresh code from your Mac."
        case .handshakeFailed: return "The secure connection to the Mac could not be established."
        case .lookupFailed, .notFound: return "The Mac could not be found. Copy a fresh pairing code that includes its current address."
        case .needsLogin: return "Connect Tailscale on both devices first."
        case .notSupported: return "This connection type is unavailable."
        case .internalError(let message): return message
        }
    }
}

/// Opens an authenticated plaintext stream to `expected` at `address`.
public protocol OrbitPeerDialing: Sendable {
    func dial(_ address: OrbitPeerAddress, expecting expected: DeviceID) async throws -> any BEPByteStream
}

public struct OrbitDiscoveryResult: Equatable, Sendable {
    public var addresses: [OrbitPeerAddress]
    public var seen: Date?
    public init(addresses: [OrbitPeerAddress], seen: Date?) {
        self.addresses = addresses
        self.seen = seen
    }
}

/// Global discovery lookup.
public protocol OrbitPeerLookup: Sendable {
    func lookup(_ device: DeviceID) async throws -> OrbitDiscoveryResult
}

/// Global discovery announce. Returns the seconds after which to announce again.
public protocol OrbitPeerAnnouncing: Sendable {
    func announce(addresses: [String]) async throws -> TimeInterval
}

public struct OrbitAcceptedPeer: Sendable {
    public let stream: any BEPByteStream
    public let device: DeviceID
    public let remoteDescription: String
    public init(stream: any BEPByteStream, device: DeviceID, remoteDescription: String) {
        self.stream = stream
        self.device = device
        self.remoteDescription = remoteDescription
    }
}

/// A listener that yields authenticated connections. The listener verifies
/// the TLS identity; the caller decides whether the device is welcome.
public protocol OrbitPeerListening: AnyObject, Sendable {
    func accept() async throws -> OrbitAcceptedPeer
    /// The addresses to announce for this listener, in Syncthing URL form.
    var announcedAddresses: [String] { get async }
    func close()
}

/// The local identity: a certificate and its device ID.
public protocol OrbitIdentityProviding: Sendable {
    var deviceID: DeviceID { get }
}
