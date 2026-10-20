import Foundation
import CryptoKit
import OrbitCore

public actor CodeJobs {
    public let root: URL
    private var jobs: [String: CodeJob] = [:]
    private var processes: [String: CodeProcess] = [:]
    private var waiting: [(CodeRequest, CodeProject, CodeJob, CodeProcess)] = []
    private let installGate = CodeInstallHandoffGate()
    private var workloads: [String: Int] = [:]
    private var requests: [String: String] = [:]
    public init(root: URL) throws {
        self.root = root
        workloads = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: root.appendingPathComponent("BuildWorkloads.json")))) ?? [:]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        CodeProfileRefresh.recover(root: root)
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            if var job = try? JSONDecoder().decode(CodeJob.self, from: Data(contentsOf: url)) {
                if job.state == .running, job.artifact != nil { job.state = .succeeded }
                if job.state == .running { job.progress?.stoppedAt = Date(); job.state = .failed; job.failureMessage = "Mac companion restarted before this job completed."; job.log += "\n" + job.failureMessage! }
                try JSONEncoder().encode(job).write(to: url, options: .atomic)
                jobs[job.id] = job
                if let request = job.requestID { requests[request] = job.id }
            }
        }
    }
    public func derivedData(_ project: CodeProject) -> URL {
        let key = SHA256.hash(data: Data((project.path + project.scheme).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("DerivedData-" + key)
    }
    public func start(_ request: CodeRequest) throws -> CodeJob {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }.joined()
        if let id = requests[request.id], let existing = jobs[id] {
            guard existing.requestFingerprint == nil || existing.requestFingerprint == fingerprint else { throw CodeFailure("A request ID was reused with different content.") }
            return existing
        }
        let overnight = request.operation == .runOnDevice && request.deviceBuild?.installOnly == true
        guard processes.isEmpty || overnight else { throw CodeFailure("A Mac build is already running. Wait for it or cancel it first.") }
        guard let project = request.project, FileManager.default.fileExists(atPath: project.path),
              ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: project.path).pathExtension),
              !project.scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodeFailure("Select an Xcode project or workspace and scheme first.")
        }
        if request.operation == .runOnDevice {
            guard request.deviceBuild != nil, !project.scheme.lowercased().contains("webdriveragent") else { throw CodeFailure("Select an app scheme and phone first.") }
        }
        if let target = request.deviceBuild?.artifactTarget {
            guard target.project == request.project, target.deviceID == request.deviceBuild?.deviceID,
                  target.branch == request.deviceBuild?.branch, overnight else { throw CodeFailure("The artifact target does not match this build request.") }
        }
        let title = overnight ? "Overnight Build · " + project.scheme : request.operation == .runOnDevice ? "Build & Run · " + project.scheme : request.operation == .deploy ? "Build & Deploy" : (request.operation == .prepare ? "Prepare Code Intelligence" : "Build")
        var job = CodeJob(id: UUID().uuidString, title: title)
        job.projectKey = project.path + "\u{0}" + project.scheme; job.requestID = request.id; job.requestFingerprint = fingerprint
        job.progress = CodeJobProgress(stage: "Preparing on your Mac…", start: 0.05, end: 0.05, estimatedSeconds: 15, reportedFraction: 0.05)
        jobs[job.id] = job; requests[request.id] = job.id
        let process = CodeProcess(); processes[job.id] = process
        do { try persistRequired(job) } catch {
            jobs[job.id] = nil; requests[request.id] = nil; processes[job.id] = nil; throw error
        }
        if processes.count == 1 {
            Task { await execute(request, project: project, job: job, process: process) }
        } else {
            stage(job.id, "Waiting for another Mac build…", from: 0.05, to: 0.05, seconds: 1)
            waiting.append((request, project, job, process))
        }
        return jobs[job.id]!
    }
    public func history(_ apps: [CodeBuildApp]) -> [CodeBuildApp] {
        apps.map { app in
            var app = app
            if let latest = jobs.values.filter({ $0.projectKey == app.key && $0.builtAt != nil })
                .max(by: { $0.builtAt! < $1.builtAt! }) {
                app.lastBuiltAt = latest.builtAt; app.commitHash = latest.commitHash
            }
            return app
        }
    }
    func recordArtifact(_ id: String, artifact: CodeBuildArtifact) throws {
        guard var job = jobs[id], job.state == .running else { throw CancellationError() }
        job.artifact = artifact
        try persistRequired(job); jobs[id] = job
    }
    func recordCompilation(_ id: String, revision: String?) {
        guard var job = jobs[id] else { return }
        job.builtAt = Date(); job.commitHash = revision; jobs[id] = job; persist(job)
    }
    public func status(_ id: String) throws -> CodeJob {
        guard var job = jobs[id] else { throw CodeFailure("This build job is no longer available.") }
        let url = root.appendingPathComponent(id + ".log")
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let length = try? handle.seekToEnd() {
                try? handle.seek(toOffset: length > 120_000 ? length - 120_000 : 0)
                let data = (try? handle.readToEnd()) ?? Data()
                job.log = (length > 120_000 ? "Earlier output remains in the Mac job log.\n" : "") + String(decoding: data, as: UTF8.self) + job.log
            }
        }
        return job
    }
    public func cancel(_ id: String) async throws -> CodeJob {
        guard var job = jobs[id] else { throw CodeFailure("Unknown build job.") }
        if job.state == .running { processes[id]?.cancel(); job.progress?.stoppedAt = Date(); job.state = .cancelled; jobs[id] = job; persist(job) }
        await installGate.cancel(id)
        return try status(id)
    }
    func stage(_ id: String, _ title: String, from start: Double, to end: Double, seconds: Double) {
        guard var job = jobs[id], job.state == .running else { return }
        let completed = job.progress?.completedTasks
        job.progress = CodeJobProgress(stage: title, start: start, end: start, estimatedSeconds: seconds, reportedFraction: start)
        job.progress?.completedTasks = completed; job.progress?.activeTasks = completed == nil ? nil : 0
        jobs[id] = job; persist(job)
    }
    public func acknowledgeInstall(_ id: String, token: String?) async throws -> CodeJob {
        guard jobs[id]?.state == .running, jobs[id]?.installHandoff != nil else { throw CodeFailure("This build is not waiting for an update handoff.") }
        let handoff = try await installGate.acknowledge(id, token: token)
        guard var job = jobs[id], job.state == .running else { throw CodeFailure("This build is no longer running.") }
        job.installHandoff = handoff; jobs[id] = job; persist(job)
        return try status(id)
    }
    func waitForInstallHandoff(_ id: String) async throws {
        let handoff = await installGate.prepare(id)
        guard var job = jobs[id], job.state == .running else { await installGate.cancel(id); throw CancellationError() }
        job.installHandoff = handoff; jobs[id] = job
        stage(id, "Build complete — ready to update Orbit", from: 0.80, to: 0.80, seconds: 1)
        try await installGate.wait(id)
        guard jobs[id]?.state == .running else { throw CancellationError() }
    }
    /// The percentage is a work estimate: counts come from real task completion,
    /// with the preceding successful workload as the denominator when available.
    func runBuildCommand(_ executable: String = "/usr/bin/xcodebuild", arguments: [String], directory: String,
                         process: CodeProcess, log: URL, id: String, workloadKey: String,
                         from start: Double, to end: Double, archive: Bool = false) async throws -> Int32 {
        let events = root.appendingPathComponent(id + "-build-events.jsonl")
        let reader = try CodeBuildEventReader(url: events)
        let expected = workloads[workloadKey]
        let streamFlags = archive ? ["--archive-xcodebuild-flag=-resultStreamPath", "--archive-xcodebuild-flag=" + events.path,
            "--archive-xcodebuild-flag=-resultBundlePath", "--archive-xcodebuild-flag=" + root.appendingPathComponent(id + "-archive.xcresult").path]
                                  : ["-resultStreamPath", events.path]
        let exit = try await process.run(executable, arguments + streamFlags, directory: directory, log: log,
                                        timeout: archive ? 7200 : 3600, onTick: { [weak self] in
            if let snapshot = await reader.read() {
                await self?.recordBuildEvents(snapshot, id: id, expected: expected, from: start, to: end, archive: archive)
            }
        })
        let snapshot = await reader.drain()
        recordBuildEvents(snapshot, id: id, expected: expected, from: start, to: end, archive: archive)
        if exit == 0, snapshot.completed > 0 {
            workloads[workloadKey] = snapshot.completed
            try? JSONEncoder().encode(workloads).write(to: root.appendingPathComponent("BuildWorkloads.json"), options: .atomic)
        }
        return exit
    }
    private func recordBuildEvents(_ snapshot: CodeBuildEventSnapshot, id: String, expected: Int?, from start: Double, to end: Double, archive: Bool) {
        guard var job = jobs[id], job.state == .running else { return }
        let value = max(job.progress?.fraction() ?? start, start + (end - start) * snapshot.fraction(expectedTasks: expected))
        let operation = snapshot.buildSucceeded && archive ? "Archive complete · Exporting, uploading and processing TestFlight build…" : snapshot.operation
        job.progress = CodeJobProgress(stage: operation, start: value, end: value, estimatedSeconds: 1, reportedFraction: value)
        job.progress?.completedTasks = snapshot.completed; job.progress?.activeTasks = snapshot.active
        jobs[id] = job; persist(job)
    }
    private func persistRequired(_ job: CodeJob) throws {
        let file = root.appendingPathComponent(job.id + ".json")
        try JSONEncoder().encode(job).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.synchronize()
    }
    private func persist(_ job: CodeJob) { try? persistRequired(job) }
    private func execute(_ request: CodeRequest, project: CodeProject, job: CodeJob, process: CodeProcess) async {
        var completed = job
        let log = root.appendingPathComponent(job.id + ".log")
        let revision: String?
        if request.operation == .runOnDevice { revision = nil } // Uses the detached checkout's exact revision instead.
        else { revision = try? await CodeDeviceSupport.git(["rev-parse", "HEAD"], directory: project.root, root: root, process: process) }
        do {
            let exit: Int32
            if request.operation == .runOnDevice {
                try await runOnDevice(request, project: project, job: job, process: process, log: log)
                exit = 0
            } else if request.operation == .deploy {
                guard !project.appID.isEmpty, !project.groupID.isEmpty else { throw CodeFailure("Set the App Store Connect app ID and internal testing group ID in Project Settings.") }
                let asc = try Self.ascExecutable()
                // Verify the destination really is an internal group before uploading.
                stage(job.id, "Checking TestFlight group…", from: 0.10, to: 0.15, seconds: 15)
                let groupsLog = root.appendingPathComponent(job.id + "-groups.log")
                let result = try await process.run(asc, ["testflight", "groups", "list", "--app", project.appID, "--paginate", "--output", "json"], directory: project.root, log: groupsLog, timeout: 60)
                guard result == 0, let json = try JSONSerialization.jsonObject(with: Data(contentsOf: groupsLog)) as? [String: Any],
                    let groups = json["data"] as? [[String: Any]], groups.contains(where: {
                        $0["id"] as? String == project.groupID && ($0["attributes"] as? [String: Any])?["isInternalGroup"] as? Bool == true
                    }) else { throw CodeFailure("Could not verify this internal testing group. Check the app/group IDs and existing asc API-key authentication on the Mac.") }
                let export = root.appendingPathComponent(job.id + "-ExportOptions.plist")
                let options: [String: Any] = ["method": "app-store-connect", "signingStyle": "automatic", "destination": "export", "manageAppVersionAndBuildNumber": false]
                try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0).write(to: export)
                let target = project.path.hasSuffix(".xcworkspace") ? "--workspace" : "--project"
                stage(job.id, "Archiving, uploading and processing TestFlight build…", from: 0.15, to: 0.99, seconds: 900)
                exit = try await runBuildCommand(asc, arguments: ["publish", "testflight", "--app", project.appID,
                    target, project.path, "--scheme", project.scheme, "--configuration", "Release",
                    "--group", project.groupID, "--wait", "--timeout", "60m",
                    "--archive-path", root.appendingPathComponent(job.id + ".xcarchive").path,
                    "--ipa-path", root.appendingPathComponent(job.id + ".ipa").path,
                    "--export-options", export.path,
                    "--archive-xcodebuild-flag=-allowProvisioningUpdates", "--export-xcodebuild-flag=-allowProvisioningUpdates"],
                    directory: project.root, process: process, log: log, id: job.id,
                    workloadKey: project.path + "|" + project.scheme + "|archive", from: 0.15, to: 0.75, archive: true)
            } else {
                stage(job.id, "Compiling on your Mac…", from: 0.10, to: 0.99, seconds: 240)
                exit = try await runBuildCommand(arguments: project.xcodeArguments + ["-configuration", "Debug",
                    "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", derivedData(project).path, "-resultBundlePath", root.appendingPathComponent(job.id + ".xcresult").path, "build"],
                    directory: project.root, process: process, log: log, id: job.id,
                    workloadKey: project.path + "|" + project.scheme + "|simulator", from: 0.10, to: 0.99)
            }
            if exit == 0, request.operation != .runOnDevice { recordCompilation(job.id, revision: revision) }
            completed.state = exit == 0 ? .succeeded : .failed
            if exit == 0, request.operation == .deploy { completed.log = "\nAvailable to the internal group after processing. Open TestFlight on your iPhone to install." }
        } catch is CancellationError { completed.state = .cancelled }
        catch { completed.state = .failed; completed.failureMessage = error.localizedDescription; completed.log = "\n" + error.localizedDescription }
        if jobs[job.id]?.state == .cancelled { completed.state = .cancelled }
        completed.artifact = jobs[job.id]?.artifact
        completed.builtAt = jobs[job.id]?.builtAt
        completed.commitHash = jobs[job.id]?.commitHash
        completed.installHandoff = jobs[job.id]?.installHandoff
        completed.progress = jobs[job.id]?.progress
        if completed.progress?.stoppedAt == nil { completed.progress?.stoppedAt = Date() }
        jobs[job.id] = completed; processes[job.id] = nil; persist(completed)
        await installGate.cancel(job.id)
        while !waiting.isEmpty {
            let (next, project, job, process) = waiting.removeFirst()
            guard jobs[job.id]?.state == .running else { processes[job.id] = nil; continue }
            Task { await execute(next, project: project, job: job, process: process) }
            break
        }
    }
    public static func ascExecutable() throws -> String {
        let paths = [ProcessInfo.processInfo.environment["ORBIT_ASC_PATH"], NSHomeDirectory() + "/.blitz/bin/asc", "/opt/homebrew/bin/asc", "/usr/local/bin/asc"].compactMap { $0 }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodeFailure("Install asc on the Mac and configure its existing App Store Connect API key. Orbit also checks ~/.blitz/bin/asc and ORBIT_ASC_PATH.")
        }
        return path
    }
}
