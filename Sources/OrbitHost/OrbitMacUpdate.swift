import Foundation
import Darwin
import OrbitCore

/// The update worker outlives this process; progress and failures survive restart.
actor OrbitMacUpdate {
    private var starting = false
    private let root: URL
    private let bundle: Bundle
    init(root: URL, bundle: Bundle = .main) { self.root = root; self.bundle = bundle }
    private var journal: URL { root.appendingPathComponent("MacUpdate/job.json") }
    func status() -> [String: Any] {
        var value = (try? Data(contentsOf: journal)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let revision = bundle.object(forInfoDictionaryKey: "OrbitRevision") as? String ?? ""
        let path = bundle.bundleURL.path
        if ["installed", "restarting", "unknownCompletion"].contains(value["state"] as? String ?? ""),
           !revision.isEmpty, value["revision"] as? String == revision,
           bundle.object(forInfoDictionaryKey: "OrbitCanonicalPath") as? String == path {
            value["state"] = "succeeded"; value["stage"] = "Orbit Mac is up to date."
            save(value)
        } else if ["accepted", "building", "installing", "restarting"].contains(value["state"] as? String ?? ""),
                  let pid = value["pid"] as? Int32, kill(pid, 0) != 0, errno == ESRCH {
            value["state"] = "failed"; value["stage"] = "The update was interrupted. Try again."
            save(value)
        }
        // Journal paths never become phone-selected filesystem reads.
        if let log = value["logPath"] as? String,
           URL(fileURLWithPath: log).deletingLastPathComponent().standardizedFileURL == journal.deletingLastPathComponent().standardizedFileURL,
           let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: log)) {
            defer { try? file.close() }
            if let end = try? file.seekToEnd() {
                try? file.seek(toOffset: end > 12000 ? end - 12000 : 0)
                if let data = try? file.readToEnd() { value["log"] = String(decoding: data, as: UTF8.self) }
            }
        }
        value.removeValue(forKey: "logPath")
        value["runningRevision"] = revision; value["runningPath"] = path
        let source = bundle.object(forInfoDictionaryKey: "OrbitSourceRoot") as? String
        value["available"] = source.map { FileManager.default.fileExists(atPath: $0 + "/scripts/build_and_run.sh") } ?? false
        if value["stage"] == nil { value["stage"] = source == nil ? "Build Orbit Mac once from Xcode or your checkout to enable updates." : "Build the latest saved commit on your Mac." }
        return value
    }
    private func save(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? data.write(to: journal, options: .atomic)
    }
    func isActive() -> Bool { starting || ["accepted", "building", "installing", "restarting", "installed"].contains(status()["state"] as? String ?? "") }
    func start() async throws -> [String: Any] {
        if isActive() { return status() }
        starting = true
        defer { starting = false }
        guard let source = bundle.object(forInfoDictionaryKey: "OrbitSourceRoot") as? String, source.hasPrefix("/"),
              FileManager.default.fileExists(atPath: source + "/scripts/build_and_run.sh") else {
            throw CodeFailure("Build Orbit Mac once from your checkout to enable updates.")
        }
        let worker = bundle.bundleURL.appendingPathComponent("Contents/Resources/AgentTools/scripts/mac_build.py")
        guard FileManager.default.fileExists(atPath: worker.path) else { throw CodeFailure("This copy needs an update from Xcode first.") }
        let data = try await OrbitCommand.run("/usr/bin/python3", [worker.path, "--start", "--source", source])
        guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw CodeFailure("Check Mac update progress before trying again.") }
        return status()
    }
}
