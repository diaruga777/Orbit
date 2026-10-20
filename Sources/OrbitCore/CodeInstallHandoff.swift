import Foundation

/// The job remains running until installation and launch finish on the Mac.
/// Only the phone's compilation-monitoring activity ends at this boundary.
public struct CodeInstallHandoff: Codable, Equatable, Sendable {
    public var token: String
    public var acknowledged: Bool
    public init(token: String = UUID().uuidString, acknowledged: Bool = false) {
        self.token = token; self.acknowledged = acknowledged
    }
}

extension CodeJob {
    public var shouldMonitorInBackground: Bool { state == .running && installHandoff == nil }
}

extension CodeDeviceBuild {
    public func requiresInstallHandoff(for builtBundleID: String) -> Bool {
        guard let monitorBundleID, !monitorBundleID.isEmpty else { return false }
        return monitorBundleID == builtBundleID
    }
}
