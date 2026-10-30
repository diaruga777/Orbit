import Foundation

/// Each route carries its own transport pin. The original pairing stays stable.
public struct OrbitConnectionRoutes: Codable, Equatable, Sendable {
    public var provider: String
    public var pairingCodes: [String]
    public var accountPeerID: String
    public init(provider: String, pairingCodes: [String], accountPeerID: String) {
        self.provider = provider; self.pairingCodes = pairingCodes; self.accountPeerID = accountPeerID
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
