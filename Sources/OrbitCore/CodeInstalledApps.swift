import Foundation

/// Installation evidence, never a build result or a cached IPA. No signing secrets.
public struct CodeInstalledApp: Codable, Equatable, Sendable {
    public var deviceID: String
    public var bundleID: String
    public var name: String
    public var version: String
    public var build: String
    public var installedAt: Date
    public var profileExpiresAt: Date?
    public init(deviceID: String, bundleID: String, name: String, version: String, build: String,
                installedAt: Date, profileExpiresAt: Date? = nil) {
        self.deviceID = deviceID; self.bundleID = bundleID; self.name = name; self.version = version; self.build = build
        self.installedAt = installedAt; self.profileExpiresAt = profileExpiresAt
    }
    public var expiresAt: Date { profileExpiresAt ?? installedAt.addingTimeInterval(7 * 86400) }
    public static let phoneReceiptPath = "Documents/OrbitInstallation.json"
}

/// Retained separately from target schedules, logs and artifact pruning.
public final class CodeInstalledAppStore: @unchecked Sendable {
    private static let lock = NSLock()
    private let file: URL
    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("installed-apps.json")
    }
    public func apps() throws -> [CodeInstalledApp] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read()
    }
    private func read() throws -> [CodeInstalledApp] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([CodeInstalledApp].self, from: Data(contentsOf: file))
    }
    public func replace(deviceID: String, with snapshot: [CodeInstalledApp]) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var apps = try read().filter { $0.deviceID != deviceID }
        apps += snapshot.filter { $0.deviceID == deviceID }
        try JSONEncoder().encode(apps).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func record(_ app: CodeInstalledApp) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var apps = try read()
        if let index = apps.firstIndex(where: { $0.deviceID == app.deviceID && $0.bundleID == app.bundleID }) {
            guard apps[index].installedAt <= app.installedAt, apps[index] != app else { return }
            apps[index] = app
        } else { apps.append(app) }
        try JSONEncoder().encode(apps).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public struct CodeExpiryReminder: Equatable, Sendable {
    public static let notificationID = "Orbit.finish-phone-refresh"
    public let app: CodeInstalledApp
    public var key: String { app.bundleID + ":" + String(app.expiresAt.timeIntervalSince1970) }
    public var scheduledAt: Date { app.expiresAt.addingTimeInterval(-86400) }
    public static func next(apps: [CodeInstalledApp], setupComplete: Bool, at now: Date) -> Self? {
        guard !setupComplete, let app = apps.filter({ $0.expiresAt > now }).min(by: {
            $0.expiresAt == $1.expiresAt ? $0.bundleID < $1.bundleID : $0.expiresAt < $1.expiresAt
        }) else { return nil }
        return Self(app: app)
    }
    /// The newest confirmed installation wins, including a renewal on the phone.
    public static func latest(_ apps: [CodeInstalledApp]) -> [CodeInstalledApp] {
        var result: [String: CodeInstalledApp] = [:]
        for app in apps {
            let key = app.deviceID + "\u{0}" + app.bundleID
            if let old = result[key], old.installedAt > app.installedAt { continue }
            result[key] = app
        }
        return Array(result.values)
    }
}
