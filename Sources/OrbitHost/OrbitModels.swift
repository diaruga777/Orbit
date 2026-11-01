import Foundation
import OrbitCore
import OrbitWire

public struct OrbitMacDeployment: Codable, Sendable {
    public var installPath: String
    public var bundleID: String
    public var certificate: String
    /// Private catalog settings include the retained Info.plist and signing requirement.
    public var settings: Data
}

public struct OrbitTarget: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Discovery thumbnail, optional so catalogs saved by older clients still load.
    public var iconPNG: Data?
    public var project: CodeProject
    public var deviceID: String
    public var mac: OrbitMacDeployment?
    public var branch: String
    public var repository: String?
    public var intervalHours: Int
    public var enabled: Bool
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var pendingRequest: CodeRequest?
    public var jobKind: String?
    public var lastJobID: String?
    public var jobID: String?
    public var failure: String?
    public init(id: String = UUID().uuidString, name: String, project: CodeProject, deviceID: String, branch: String = "main", intervalHours: Int = 144, enabled: Bool = false) {
        self.id = id; self.name = name; self.project = project; self.deviceID = deviceID; self.branch = branch
        self.intervalHours = intervalHours; self.enabled = enabled
    }
    public func isDue(at date: Date) -> Bool {
        enabled && jobID == nil && (lastSuccess.map { date.timeIntervalSince($0) >= Double(intervalHours) * 3600 } ?? true)
            && (lastAttempt.map { date.timeIntervalSince($0) >= 1800 } ?? true)
    }
}
public struct OrbitConfiguration: Codable, Sendable {
    public var appletFolder: String?
    public var widgetFolder: String?
    public var phoneBundleID: String?
    public var listen = "0.0.0.0:49210"
    public var provider = "local"
    public var relay: String?
    public var address: String?
    public var trustedPeers: [String] = []
    /// Transport keys introduced over an already authenticated phone connection.
    public var peerAliases: [String: String]?
    public var allowedRoots: [String] = []
    public init() {}
}
public enum OrbitPaths {
    public static var root: URL {
        if let path = Bundle.main.object(forInfoDictionaryKey: "OrbitStateRoot") as? String, path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if let path = ProcessInfo.processInfo.environment["ORBIT_HOME"], path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orbit", isDirectory: true)
    }
}

extension OrbitConfiguration {
    func validateConnection(requireAddress: Bool = false) throws {
        guard ["local", "tailscale", "syncthing", "dumbpipe"].contains(provider) else { throw CodeFailure("Choose a connection type.") }
        guard requireAddress else { return }
        if provider == "tailscale" {
            guard let address, case .tcp = OrbitPeerAddress(syncthingURL: address) else { throw CodeFailure("Enter your Mac’s tcp:// address from Tailscale.") }
        }
        if provider == "syncthing" {
            guard let relay, let url = URLComponents(string: relay), url.scheme == "relay", let host = url.host, !host.isEmpty,
                  url.queryItems?.contains(where: { $0.name == "id" && !($0.value ?? "").isEmpty }) == true else {
                throw CodeFailure("Enter a relay:// address including its certificate ID.")
            }
        }
    }
}
