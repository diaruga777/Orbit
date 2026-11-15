import Foundation

/// Each route carries its own transport pin. The original pairing stays stable.
public struct OrbitConnectionRoutes: Codable, Equatable, Sendable {
    public var provider: String
    public var pairingCodes: [String]
    public var accountPeerID: String
    public init(provider: String, pairingCodes: [String], accountPeerID: String) {
        self.provider = provider; self.pairingCodes = pairingCodes; self.accountPeerID = accountPeerID
    }
    /// Saved configuration is authoritative, including an explicit return to LAN.
    /// This says nothing about reachability, authorization or Apple installation.
    public static func hasRemoteConnection(pairingCode: String, savedRoutes: Self?) -> Bool {
        guard let original = try? OrbitPairingCode(string: pairingCode) else { return false }
        if let savedRoutes {
            guard savedRoutes.provider != "local", let codes = try? savedRoutes.validated() else { return false }
            return !codes.isEmpty
        }
        return original.addresses.contains {
            switch $0 { case .dumbpipe, .relay, .tailscale: return true; case .tcp: return false }
        }
    }
    public struct Candidate: Sendable {
        public let code: OrbitPairingCode
        public let address: OrbitPeerAddress
    }

    public static func candidates(_ codes: [OrbitPairingCode], automatic: Bool) -> [Candidate] {
        let candidates = codes.flatMap { code in code.addresses.map { Candidate(code: code, address: $0) } }
        guard automatic else { return candidates }
        let lan = candidates.filter { if case .tcp = $0.address { return true }; return false }
        let iroh = candidates.filter { if case .dumbpipe = $0.address { return true }; return false }
        let fallback = candidates.filter {
            switch $0.address { case .tailscale, .relay: return true; default: return false }
        }
        return lan + iroh + fallback
    }

    public func validated() throws -> [OrbitPairingCode] {
        guard ["local", "tailscale", "syncthing", "dumbpipe"].contains(provider), pairingCodes.count <= 8 else {
            throw OrbitTransportError.internalError("Invalid connection update.")
        }
        _ = try DeviceID(string: accountPeerID)
        return try pairingCodes.map {
            let code = try OrbitPairingCode(string: $0)
            guard !code.addresses.isEmpty, code.addresses.count <= 16 else { throw OrbitTransportError.internalError("Invalid connection route.") }
            for route in code.addresses {
                if case .dumbpipe(let endpoint) = route {
                    guard endpoint.lowercased() == code.deviceID.bytes.map({ String(format: "%02x", $0) }).joined() else {
                        throw OrbitTransportError.internalError("Remote route identity changed.")
                    }
                }
            }
            return code
        }
    }
}
