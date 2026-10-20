import Foundation
import CryptoKit
import OSLog

/// Versioned append-oriented journal + bounded current summary. Writes must
/// succeed before acknowledgement. Hosts inject the directory, never an App Group.
public final class CodeOvernightStore: @unchecked Sendable {
    private struct Snapshot: Codable {
        var version = 1
        var invocations: [CodeOvernightInvocation] = []
        var jobs: [CodeOvernightJob] = []
        var events: [CodeOvernightDiagnosticEvent] = []
    }
    private let lock = NSRecursiveLock()
    public let root: URL
    private var snapshot: Snapshot
    private let logger = Logger(subsystem: "Orbit", category: "overnight")
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("attempts-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            guard snapshot.version == 1 else { throw CodeFailure("Update Orbit to read this attempt history.") }
        } else { snapshot = Snapshot() }
    }
    public func invocations() -> [CodeOvernightInvocation] { locked { snapshot.invocations } }
    public func jobs() -> [CodeOvernightJob] { locked { snapshot.jobs } }
    public func save(_ invocation: CodeOvernightInvocation) throws {
        try locked {
            var next = snapshot
            if let i = next.invocations.firstIndex(where: { $0.id == invocation.id }) {
                // An expiration callback must not overwrite a completed invocation.
                guard next.invocations[i].state == .started else { return }
                next.invocations[i] = invocation
            } else { next.invocations.append(invocation) }
            let event = CodeOvernightDiagnosticEvent(stage: "invocation", correlationID: invocation.id, outcome: invocation.state.rawValue)
            next.events.append(event); try commit(next); appendLogBestEffort(event)
        }
    }
    public func save(_ job: CodeOvernightJob) throws {
        try locked {
            var next = snapshot
            if let i = next.jobs.firstIndex(where: { $0.id == job.id }) {
                if job.revision == next.jobs[i].revision {
                    var previous = next.jobs[i], incoming = job
                    previous.synchronizedAt = nil; incoming.synchronizedAt = nil
                    guard previous == incoming, let sync = job.synchronizedAt,
                          sync > (next.jobs[i].synchronizedAt ?? .distantPast) else { return }
                } else { guard job.revision > next.jobs[i].revision else { return } }
                next.jobs[i] = job
            } else { next.jobs.append(job) }
            let event = CodeOvernightDiagnosticEvent(stage: "job", correlationID: job.id, outcome: job.state.rawValue)
            next.events.append(event); try commit(next); appendLogBestEffort(event)
        }
    }
    public func event(_ event: CodeOvernightDiagnosticEvent) throws {
        try locked {
            var next = snapshot; next.events.append(event)
            try commit(next)
            try appendLog(event)
        }
    }
    private func appendLogBestEffort(_ event: CodeOvernightDiagnosticEvent) {
        do { try appendLog(event) } catch { logger.error("Overnight JSONL write failed") }
    }
    private func appendLog(_ event: CodeOvernightDiagnosticEvent) throws {
            logger.info("stage=\(event.stage, privacy: .public) outcome=\(event.outcome, privacy: .public)")
            var bytes = try JSONEncoder().encode(event); bytes.append(10)
            let log = root.appendingPathComponent("events.jsonl")
            if let size = try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize, size + bytes.count > 1_000_000 {
                let previous = root.appendingPathComponent("events.previous.jsonl")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: log, to: previous)
            }
            if !FileManager.default.fileExists(atPath: log.path) { try write(Data(), to: log) }
            let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: bytes); try handle.synchronize()
    }
    /// Source keys/addresses/paths never enter JSONL. Export pseudonymizes the
    /// summary's identifiers and omits raw build logs and error descriptions.
    public func export(remote: [CodeOvernightJob]?, capabilities: CodeOvernightCapabilities?, macFiles: [String: Data]? = nil, endpoint: String = "iphone") throws -> URL {
        try locked {
            let directory = root.appendingPathComponent("Export-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let manifest: [String: Any] = ["schemaVersion": 1, "endpoint": endpoint, "osVersion": ProcessInfo.processInfo.operatingSystemVersionString, "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "remoteLogs": endpoint == "mac" ? "Mac-local journal; no phone logs requested" : (macFiles == nil ? "unavailable: Mac disconnected or diagnostics request failed" : "Mac journal included; raw compiler/installer output excluded"),
                "limitations": "Device acceptance checks pending; transport support is negotiated per peer."]
            try write(try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), to: directory.appendingPathComponent("manifest.json"))
            let data = try JSONEncoder().encode(snapshot)
            let redacted = try Self.redacted(data)
            try write(redacted, to: directory.appendingPathComponent("local.json"))
            if let remote { try write(try Self.redacted(JSONEncoder().encode(remote)), to: directory.appendingPathComponent("mac.json")) }
            if let capabilities { try write(try JSONEncoder().encode(capabilities), to: directory.appendingPathComponent("capabilities.json")) }
            for name in ["events.jsonl", "events.previous.jsonl"] {
                if let data = try? Data(contentsOf: root.appendingPathComponent(name)) {
                    let lines = try data.split(separator: 10).map { try Self.redacted(Data($0)) }
                    // Re-encode compactly: one valid JSON object per line.
                    var result = Data()
                    for line in lines { result.append(try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: line), options: [.sortedKeys])); result.append(10) }
                    try write(result, to: directory.appendingPathComponent(name))
                }
            }
            if let macFiles {
                for (name, data) in macFiles where ["manifest.json", "local.json", "events.jsonl", "events.previous.jsonl", "capabilities.json"].contains(name) {
                    guard data.count <= 3_000_000 else { continue }
                    try write(data, to: directory.appendingPathComponent("mac-" + name))
                }
            }
            let exports = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []).filter { $0.lastPathComponent.hasPrefix("Export-") }
                .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            for old in exports.dropFirst(5) where old != directory { try? FileManager.default.removeItem(at: old) }
            return directory
        }
    }
    public static func redacted(_ data: Data) throws -> Data {
        let sensitive = Set(["id", "requestID", "invocationID", "jobID", "artifactID", "sessionID", "compilationJobID", "correlationID", "peerID", "deviceID", "path", "projectKey", "key", "branch", "bundleID", "commit", "signingAuthority", "connectionDescription", "recovery", "leaseToken", "handoffToken", "signature", "privateKey", "ticket", "authTag", "relayAddress", "tailscaleAddress"])
        func visit(_ value: Any, key: String = "") -> Any {
            if sensitive.contains(key), let text = value as? String { return "redacted-" + SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() }
            if let object = value as? [String: Any] {
                return object.mapValues { $0 }.reduce(into: [String: Any]()) { $0[$1.key] = visit($1.value, key: $1.key) }
            }
            if let array = value as? [Any] { return array.map { visit($0, key: key == "jobIDs" ? "jobID" : key) } }
            return value
        }
        return try JSONSerialization.data(withJSONObject: visit(JSONSerialization.jsonObject(with: data)), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }
    public func reconcileInterruptedInvocations(at date: Date = Date()) throws {
        try locked {
            var next = snapshot
            for i in next.invocations.indices where next.invocations[i].state == .started {
                next.invocations[i].state = .unknownCompletion; next.invocations[i].endedAt = date
                next.invocations[i].error = CodeOvernightError(.interrupted, stage: "invocation", recovery: "The last attempt was interrupted. Refresh its status.")
            }
            try commit(next)
        }
    }
    private func commit(_ value: Snapshot) throws {
        var value = value
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let latestBuild = value.jobs.filter { $0.builtAt != nil }.max { $0.builtAt! < $1.builtAt! }?.id
        let latestInstall = value.jobs.filter { $0.installedAt != nil }.max { $0.installedAt! < $1.installedAt! }?.id
        value.invocations = Array(value.invocations.filter { $0.endedAt == nil || $0.startedAt > cutoff }.suffix(200))
        let active = value.jobs.filter { ([.accepted, .building].contains($0.state) || $0.hasActionableArtifact || $0.needsInstallReconciliation) || $0.id == latestBuild || $0.id == latestInstall }
        let activeIDs = Set(active.map(\.id))
        value.jobs = active + value.jobs.filter { !activeIDs.contains($0.id) && $0.acceptedAt > cutoff }.suffix(200)
        value.events = Array(value.events.suffix(1000))
        try write(try JSONEncoder().encode(value), to: root.appendingPathComponent("attempts-v1.json"))
        snapshot = value
    }
    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
}
