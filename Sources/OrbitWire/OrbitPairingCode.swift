import Foundation

/// A single copyable code carries the certificate identity and direct routes.
/// Routes are hints only: TLS must still authenticate the exact device ID.
public struct OrbitPairingCode: Equatable, Sendable {
    public let deviceID: DeviceID
    public let addresses: [OrbitPeerAddress]
    public let irohRelay: String?

    public init(deviceID: DeviceID, addresses: [OrbitPeerAddress], irohRelay: String? = nil) {
        self.irohRelay = Self.validRelay(irohRelay)
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
            irohRelay = Self.validRelay(parts.queryItems?.first { $0.name == "irohRelay" }?.value)
            deviceID = try DeviceID(string: id)
            addresses = (parts.queryItems ?? []).filter { $0.name == "address" }.compactMap {
                $0.value.flatMap(OrbitPeerAddress.init(syncthingURL:))
            }
        } else {
            deviceID = try DeviceID(string: text)
            addresses = []
            irohRelay = nil
        }
    }

    public static func validRelay(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 256, let url = URLComponents(string: value),
              url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        return value
    }

    public var text: String {
        var parts = URLComponents()
        parts.scheme = "orbit"; parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "device", value: deviceID.description)] + addresses.map {
            URLQueryItem(name: "address", value: $0.description)
        }
        if let irohRelay { parts.queryItems?.append(URLQueryItem(name: "irohRelay", value: irohRelay)) }
        return parts.string!
    }
}
