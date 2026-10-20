import Foundation

/// A single copyable code carries the certificate identity and direct routes.
/// Routes are hints only: TLS must still authenticate the exact device ID.
public struct OrbitPairingCode: Equatable, Sendable {
    public let deviceID: DeviceID
    public let addresses: [OrbitPeerAddress]

    public init(deviceID: DeviceID, addresses: [OrbitPeerAddress]) {
        self.deviceID = deviceID
        self.addresses = addresses.filter {
            if case .tcp(let host, _) = $0 { return host != "0.0.0.0" && host != "::" }
            return true
        }.sorted { $0.dialPriority < $1.dialPriority }
    }

    public init(string: String) throws {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parts = URLComponents(string: text),
           ["orbit", "orbit"].contains(parts.scheme?.lowercased() ?? ""), parts.host == "pair" {
            guard let id = parts.queryItems?.first(where: { $0.name == "device" })?.value else {
                throw OrbitTransportError.internalError("The pairing code has no Mac identity.")
            }
            deviceID = try DeviceID(string: id)
            addresses = (parts.queryItems ?? []).filter { $0.name == "address" }.compactMap {
                $0.value.flatMap(OrbitPeerAddress.init(syncthingURL:))
            }
        } else {
            deviceID = try DeviceID(string: text)
            addresses = []
        }
    }

    public var text: String {
        var parts = URLComponents()
        parts.scheme = "orbit"; parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "device", value: deviceID.description)] + addresses.map {
            URLQueryItem(name: "address", value: $0.description)
        }
        return parts.string!
    }
}
