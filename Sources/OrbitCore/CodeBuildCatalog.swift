import Foundation

public struct CodeDevice: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct CodeBuildApp: Codable, Equatable, Sendable {
    public var project: CodeProject
    public var name: String
    public var bundleID: String
    /// Small PNG supplied by the Mac; optional for older peers and cached rows.
    public var iconPNG: Data?
    public var branch: String
    public var deviceID: String?
    public var jobID: String?
    public var lastBuiltAt: Date?
    public var commitHash: String?
    // Optional wire fields preserve caches and requests from older versions.
    public var nightlyEnabled: Bool?
    public var lastNightlyAttempt: Date?
    public var nightlyFailure: String?
    public var lastInstalledAt: Date?
    public var key: String { project.path + "\u{0}" + project.scheme }
    public init(project: CodeProject, name: String, bundleID: String, branch: String = "main", deviceID: String? = nil) {
        self.project = project; self.name = name; self.bundleID = bundleID; self.branch = branch; self.deviceID = deviceID
    }
}
public struct CodeDeviceBuild: Codable, Equatable, Sendable {
    public var branch: String
    public var deviceID: String
    public var monitorBundleID: String?
    public var installOnly: Bool?
    public var artifactTarget: CodeOvernightTarget?
    public init(branch: String = "main", deviceID: String, monitorBundleID: String? = nil) {
        self.branch = branch; self.deviceID = deviceID; self.monitorBundleID = monitorBundleID
    }
}

/// Local cache is isolated by paired Mac. Row settings never change the editor's project.
public final class CodeBuildCatalog {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public var selectedTab: Int {
        get { defaults.integer(forKey: "Code.selectedTab") == 1 ? 1 : 0 }
        set { defaults.set(newValue == 1 ? 1 : 0, forKey: "Code.selectedTab") }
    }
    public func apps(peer: String) -> [CodeBuildApp] {
        defaults.data(forKey: "Code.buildApps." + peer).flatMap { try? JSONDecoder().decode([CodeBuildApp].self, from: $0) } ?? []
    }
    public func save(_ apps: [CodeBuildApp], peer: String) {
        defaults.set(try? JSONEncoder().encode(apps), forKey: "Code.buildApps." + peer)
    }
    public func merge(_ discovered: [CodeBuildApp], path: String, peer: String) {
        let old = apps(peer: peer)
        let updated = discovered.map { app -> CodeBuildApp in
            guard let previous = old.first(where: { $0.key == app.key }) else { return app }
            var result = app; result.branch = previous.branch; result.deviceID = previous.deviceID; result.jobID = previous.jobID
            result.nightlyEnabled = previous.nightlyEnabled
            result.lastNightlyAttempt = previous.lastNightlyAttempt
            result.nightlyFailure = previous.nightlyFailure
            result.lastInstalledAt = previous.lastInstalledAt
            if let date = previous.lastBuiltAt, date > (result.lastBuiltAt ?? .distantPast) {
                result.lastBuiltAt = date; result.commitHash = previous.commitHash
            }
            return result
        }
        save((old.filter { $0.project.path != path } + updated).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }, peer: peer)
    }
    public func defaultDevice(peer: String) -> String? { defaults.string(forKey: "Code.defaultDevice." + peer) }
    public func setDefaultDevice(_ id: String?, peer: String) { defaults.set(id, forKey: "Code.defaultDevice." + peer) }

    public func record(_ job: CodeJob, peer: String) {
        var rows = apps(peer: peer)
        for index in rows.indices where rows[index].jobID == job.id || rows[index].key == job.projectKey {
            guard let date = job.builtAt, date >= (rows[index].lastBuiltAt ?? .distantPast) else { continue }
            rows[index].lastBuiltAt = date; rows[index].commitHash = job.commitHash
        }
        save(rows, peer: peer)
    }
    public func edit(key: String, peer: String, _ change: (inout CodeBuildApp) -> Void) {
        var rows = apps(peer: peer)
        guard let index = rows.firstIndex(where: { $0.key == key }) else { return }
        change(&rows[index]); save(rows, peer: peer)
    }

    public static func resolveDevice(_ devices: [CodeDevice], preferred: String?, currentName: String) -> CodeDevice? {
        // A saved device never silently falls back to a different phone.
        if let preferred { return devices.first { $0.id == preferred } }
        let matches = devices.filter { $0.name == currentName }
        if matches.count == 1 { return matches[0] }
        return devices.count == 1 ? devices[0] : nil
    }
}
