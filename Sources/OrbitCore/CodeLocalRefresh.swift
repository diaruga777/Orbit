import Foundation

/// Public status contains no Apple session, signing key or pairing material.
public struct CodeLocalRefreshApp: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case ready, signing, installing, unknown, confirmed, failed }
    public let id: String
    public var name: String
    public var bundleID: String
    public var teamID: String
    public var version: String
    public var build: String
    public var expiresAt: Date
    public var automatic = false
    public var state: State = .ready
    public var lastAttempt: Date?
    public var lastConfirmed: Date?
    public var failure: String?
    public var pendingProfiles: [String: Date] = [:]
    public init(id: String = UUID().uuidString, name: String, bundleID: String, teamID: String,
                version: String, build: String, expiresAt: Date) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.teamID = teamID
        self.version = version; self.build = build; self.expiresAt = expiresAt
    }
    public func isDue(at date: Date) -> Bool {
        automatic && ![.installing, .unknown, .signing].contains(state)
            && expiresAt.timeIntervalSince(date) <= 48 * 3600
            && (lastAttempt.map { date.timeIntervalSince($0) >= 3600 } ?? true)
    }
    /// A killed self-update or lost installation reply is never a reason to
    /// silently issue another installation. Read back first on the next launch.
    public var requiresReconciliation: Bool { state == .installing || state == .unknown }
    public mutating func confirm(version: String, build: String, installedProfiles: [String: Date], at date: Date) throws {
        guard self.version == version, self.build == build, !pendingProfiles.isEmpty,
              pendingProfiles.allSatisfy({ installedProfiles[$0.key] == $0.value && $0.value > date }),
              let expiry = pendingProfiles.values.min() else {
            throw CodeFailure("The refreshed build hasn’t been confirmed on this phone yet.")
        }
        state = .confirmed; expiresAt = expiry; lastConfirmed = date; failure = nil; pendingProfiles = [:]
    }
}

/// Each app owns an immutable cached build and a separate signing workspace.
/// Journal the intended profiles before installation, including self replacement.
public final class CodeLocalRefreshStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSRecursiveLock()
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        var url = root, values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
        #endif
    }
    public func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CodeFailure("Invalid cached build.") }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    public func apps() -> [CodeLocalRefreshApp] {
        lock.lock(); defer { lock.unlock() }
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).compactMap {
            guard UUID(uuidString: $0.lastPathComponent) != nil else { return nil }
            return try? JSONDecoder().decode(CodeLocalRefreshApp.self, from: Data(contentsOf: $0.appendingPathComponent("refresh.json")))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func save(_ app: CodeLocalRefreshApp) throws {
        lock.lock(); defer { lock.unlock() }
        let directory = try directory(app.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("refresh.json")
        try JSONEncoder().encode(app).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        NotificationCenter.default.post(name: .codeRefreshStateChanged, object: nil)
    }
    public func remove(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !apps().contains(where: { $0.id == id && $0.requiresReconciliation }) else {
            throw CodeFailure("Check this app’s installation before removing its cached build.")
        }
        try FileManager.default.removeItem(at: directory(id))
    }
}

public struct CodeRefreshArchiveChunk: Codable, Sendable {
    public var artifactID: String
    public var digest: String
    public var byteCount: Int
    public var offset: Int
    public var bytes: Data
    public init(artifactID: String, digest: String, byteCount: Int, offset: Int, bytes: Data) {
        self.artifactID = artifactID; self.digest = digest; self.byteCount = byteCount; self.offset = offset; self.bytes = bytes
    }
}

extension Notification.Name {
    public static let codeRefreshStateChanged = Notification.Name("Orbit.refreshStateChanged")
}
