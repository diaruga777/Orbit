import Foundation
import OrbitCore
import OrbitMac

/// Durable host-owned Mac jobs use the same catalog and scheduler as phone apps.
actor OrbitMacTargets {
    private let root: URL
    init(root: URL) { self.root = root.appendingPathComponent("MacTargets") }
    private var worker: URL { Bundle.module.url(forResource: "MacTargets", withExtension: nil)!.appendingPathComponent("mac_target.py") }
    private func execute(_ command: String, _ path: URL) async throws -> Data {
        // Python's subprocesses inherit the same full Xcode used by phone builds.
        let environment = try CodeXcodeTools.environment(for: "/usr/bin/swift")
        return try await OrbitCommand.run("/usr/bin/env", ["DEVELOPER_DIR=" + (environment["DEVELOPER_DIR"] ?? ""), "/usr/bin/python3", worker.path, command, path.path])
    }
    func inspect(_ params: [String: Any]) async throws -> OrbitMacDeployment {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try write(JSONSerialization.data(withJSONObject: params), to: file)
        let data = try await execute("inspect", file)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let installPath = value["installPath"] as? String, let bundleID = value["bundleID"] as? String,
              let certificate = value["certificate"] as? String else { throw CodeFailure("Couldn’t read the Mac app’s signing settings.") }
        return OrbitMacDeployment(installPath: installPath, bundleID: bundleID, certificate: certificate, settings: data)
    }
    func start(_ target: OrbitTarget, branch: String, launch: Bool) async throws -> [String: Any] {
        guard let deployment = target.mac else { throw CodeFailure("Choose a Mac app.") }
        // The ID is saved in targets.json before dispatch; restart retries reuse it.
        let id = target.jobID ?? UUID().uuidString
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let journal = folder.appendingPathComponent("job.json")
        if FileManager.default.fileExists(atPath: journal.path) { return try await job(id) }
        var settings = try JSONSerialization.jsonObject(with: deployment.settings) as? [String: Any] ?? [:]
        settings["branch"] = branch
        try write(JSONSerialization.data(withJSONObject: settings), to: folder.appendingPathComponent("config.json"))
        try write(JSONSerialization.data(withJSONObject: ["id": id, "title": "Build · " + target.name, "state": "running", "stage": "Starting on this Mac…", "launch": launch, "createdAt": Date().timeIntervalSince1970]), to: journal)
        do { return try wire(await execute("start", journal)) }
        catch {
            try? write(JSONSerialization.data(withJSONObject: ["id": id, "state": "failed", "failureMessage": error.localizedDescription]), to: journal)
            throw error
        }
    }
    func hasJournal(_ id: String) -> Bool {
        guard UUID(uuidString: id) != nil else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(id).appendingPathComponent("job.json").path)
    }
    func job(_ id: String, cancel: Bool = false) async throws -> [String: Any] {
        guard UUID(uuidString: id) != nil else { throw CodeFailure("Invalid Mac job ID.") }
        let journal = root.appendingPathComponent(id).appendingPathComponent("job.json")
        guard FileManager.default.fileExists(atPath: journal.path) else {
            // Catalog persistence precedes worker dispatch. A crash in between is safe to retry.
            return ["id": id, "state": "failed", "platform": "macOS", "title": "Mac build", "startedAt": Date().timeIntervalSinceReferenceDate, "log": "", "failureMessage": "The Mac restarted before this build started. Try again."]
        }
        return try wire(await execute(cancel ? "cancel" : "status", journal))
    }
    private func wire(_ data: Data) throws -> [String: Any] {
        var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        value["platform"] = "macOS"; value["log"] = value["log"] ?? ""; value["title"] = value["title"] ?? "Mac build"
        value["startedAt"] = (value["createdAt"] as? Double ?? Date().timeIntervalSince1970) - Date.timeIntervalBetween1970AndReferenceDate
        let phase = value["phase"] as? String ?? "building"
        let fraction = phase == "installing" ? 0.85 : phase == "launching" ? 0.95 : 0.05
        var progress = CodeJobProgress(stage: value["stage"] as? String ?? "Building on this Mac…", start: fraction, end: phase == "building" ? 0.8 : fraction, estimatedSeconds: 180,
            startedAt: Date(timeIntervalSinceReferenceDate: value["startedAt"] as? Double ?? 0))
        if value["state"] as? String != "running" { progress.stoppedAt = Date() }
        value["progress"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress))
        return value
    }
    private func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
