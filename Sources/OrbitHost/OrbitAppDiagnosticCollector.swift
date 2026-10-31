import Foundation
import CryptoKit
import OrbitCore
import OrbitMac

public struct OrbitAppDiagnosticStatus: Codable, Sendable {
    public let id: String
    public let deviceID: String
    public let bundleID: String
    public var version: String
    public var build: String
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var state: String
}

/// Collect only apps with confirmed Orbit install evidence. Apple pairing and
/// exact UDID checks are owned by CodeAppleEndpointContainer, not a control pipe.
public actor OrbitAppDiagnosticCollector {
    public typealias ReadFiles = @Sendable (CodeInstalledApp) async throws -> [Data]
    private let root: URL
    private let readFiles: ReadFiles
    private var statuses: [String: OrbitAppDiagnosticStatus]
    private var collecting = false
    public init(root: URL, readFiles: ReadFiles? = nil) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        statuses = (try? JSONDecoder().decode([String: OrbitAppDiagnosticStatus].self,
            from: Data(contentsOf: root.appendingPathComponent("status.json")))) ?? [:]
        self.readFiles = readFiles ?? { app in
            try await CodeAppleEndpointContainer(root: root.appendingPathComponent("Scratch"), bundleID: app.bundleID)
                .readDiagnosticFiles(deviceID: app.deviceID)
        }
    }
    public static func id(_ app: CodeInstalledApp) -> String {
        SHA256.hash(data: Data((app.deviceID + "\u{0}" + app.bundleID).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func list() -> [OrbitAppDiagnosticStatus] { statuses.values.sorted { $0.id < $1.id } }
    public func events(app id: String, maximum: Int) throws -> [OrbitDiagnosticEvent] {
        guard statuses[id] != nil, id.count == 64, id.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw CodeFailure("App diagnostics not found.") }
        let events = OrbitDiagnostics.store(directory: root.appendingPathComponent(id)).recent(maximum: 500)
        // A rotation during native copying can deliver earlier events on a later
        // pass. Order each source session by its writer sequence, not arrival.
        var sessions: [String] = []
        for event in events where !sessions.contains(event.session) { sessions.append(event.session) }
        let ordered = sessions.flatMap { session in
            let group = events.filter { $0.session == session }
            guard group.allSatisfy({ $0.sequence != nil }) else { return group }
            return group.sorted { $0.sequence! < $1.sequence! }
        }
        return Array(ordered.suffix(max(0, min(500, maximum))))
    }
    /// One app per pass; unavailable/uninstrumented apps back off. This loop never
    /// launches an app, requests sign-in or changes install/schedule state.
    public func collect(_ apps: [CodeInstalledApp], now: Date = Date()) async {
        guard !collecting else { return }
        collecting = true; defer { collecting = false }
        for app in apps {
            let id = Self.id(app)
            if statuses[id] == nil {
                statuses[id] = .init(id: id, deviceID: app.deviceID, bundleID: app.bundleID,
                    version: app.version, build: app.build, state: "waiting")
            }
        }
        let eligible = apps.filter { app in
            let state = statuses[Self.id(app)]!
            return state.lastAttempt.map { now.timeIntervalSince($0) >= (state.state == "receiving" ? 10 : 60) } ?? true
        }.sorted { (statuses[Self.id($0)]?.lastAttempt ?? .distantPast) < (statuses[Self.id($1)]?.lastAttempt ?? .distantPast) }
        guard let app = eligible.first else { return }
        let id = Self.id(app)
        statuses[id]?.lastAttempt = now
        statuses[id]?.version = app.version; statuses[id]?.build = app.build
        do {
            let files = try await readFiles(app)
            try Self.importFiles(files, into: OrbitDiagnostics.store(directory: root.appendingPathComponent(id)))
            statuses[id]?.lastSuccess = now; statuses[id]?.state = "receiving"
        } catch {
            // Apple errors may include account names or container paths. Agent
            // status is honest but contains no raw native-tool transcript.
            statuses[id]?.state = "unavailable"
        }
        if let data = try? JSONEncoder().encode(statuses) {
            try? data.write(to: root.appendingPathComponent("status.json"), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("status.json").path)
        }
    }
    public static func importFiles(_ files: [Data], into journal: OrbitDiagnostics) throws {
        guard files.count <= 4, files.allSatisfy({ $0.count <= 1024 * 1024 + 16384 }) else { throw CodeFailure("App diagnostic batch exceeded its limit.") }
        for data in files {
            // A concurrent writer may leave an incomplete final line. Retry it
            // next time; UUID deduplication handles the repeated complete lines.
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            var batch: [OrbitDiagnosticEvent] = []
            for line in lines.dropLast() {
                guard line.count <= 16384, let event = try? JSONDecoder().decode(OrbitDiagnosticEvent.self, from: Data(line)) else { continue }
                batch.append(event)
                if batch.count == 128 { try journal.append(batch); batch = [] }
            }
            try journal.append(batch)
        }
    }
}
