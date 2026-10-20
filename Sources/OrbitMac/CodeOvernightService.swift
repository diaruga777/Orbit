import Foundation
import OrbitCore

/// Durable compilation/artifact/install dimensions, independent of the lifetime
/// of a control connection. A single executor serializes installs on this Mac.
public actor CodeOvernightService {
    private let store: CodeOvernightStore
    private let builds: CodeJobs
    private let artifacts: CodeArtifactStore
    private let installer: any CodeArtifactInstalling
    private var workers: [String: Task<Void, Never>] = [:]
    private var installProcesses: [String: CodeProcess] = [:]
    private var installBusy = false
    private var recovered = false
    private let proxyAvailable: Bool
    public init(root: URL, builds: CodeJobs, installer: (any CodeArtifactInstalling)? = nil, remote: CodeReverseInstallerConfiguration? = nil, journal: CodeOvernightStore? = nil) throws {
        self.builds = builds
        let journal = try journal ?? CodeOvernightStore(root: root.appendingPathComponent("Overnight")); store = journal
        artifacts = try CodeArtifactStore(root: root.appendingPathComponent("Jobs/Artifacts"))
        let native = CodeNativeInstaller(logs: root.appendingPathComponent("Overnight"), record: { try? journal.event($0) })
        proxyAvailable = remote?.available == true
        if let installer { self.installer = installer }
        else if let remote, remote.available { self.installer = CodeFallbackInstaller(native: native, remote: CodeReverseInstaller(configuration: remote)) }
        else { self.installer = native }
    }
    public func diagnostics() throws -> [String: Data] {
        let directory = try store.export(remote: nil, capabilities: capabilities(), endpoint: "mac")
        defer { try? FileManager.default.removeItem(at: directory) }
        return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
    public func capabilities() -> CodeOvernightCapabilities {
        var value = CodeOvernightCapabilities(); value.deviceFlowProxy = proxyAvailable
        if proxyAvailable { value.providers += [.local, .tailscale, .syncthing, .dumbpipe] }
        return value
    }
    public func submit(_ request: CodeRequest) async throws -> CodeOvernightJob {
        try await recover()
        guard let submission = request.overnight, !submission.target.deviceID.isEmpty,
              submission.target.project.path.hasPrefix("/"), !submission.target.project.scheme.isEmpty,
              !submission.target.project.scheme.lowercased().contains("webdriveragent") else { throw CodeFailure("Choose an app and target phone first.") }
        if let previous = store.jobs().first(where: { $0.requestID == request.id }) {
            guard previous.target == submission.target else { throw CodeFailure("A request ID was reused with a different target.") }
            return previous
        }
        // Definitively invalid/expired artifacts can be rebuilt. Uncertain
        // installation evidence must still reconcile the existing revision.
        for var old in store.jobs() where Self.sameDestination(old.target, submission.target) && Self.canReplaceFailedArtifact(old) {
            old.state = .cancelled; old.revision += 1; try store.save(old)
        }
        // A missed installation cannot create a fresh artifact each day, even
        // when a schedule generation or source ref has since changed.
        if let existing = store.jobs().first(where: { Self.sameDestination($0.target, submission.target) && ([.accepted, .building].contains($0.state) || $0.hasActionableArtifact) }) {
            return existing
        }
        let job = CodeOvernightJob(requestID: request.id, invocationID: submission.invocationID, target: submission.target)
        try store.save(job) // Required durable acknowledgement boundary.
        workers[job.id] = Task { await self.compile(job.id) }
        return job
    }
    public func status() async throws -> [CodeOvernightJob] { try await recover(); return store.jobs() }
    public func retryInstall(_ id: String) async throws -> CodeOvernightJob {
        try await recover()
        guard let job = store.jobs().first(where: { $0.id == id }) else { throw CodeFailure("This overnight job is no longer available.") }
        if job.hasActionableArtifact || (job.state == .failed && job.artifact != nil) {
            if workers[id] == nil { workers[id] = Task { await self.install(id) } }
        }
        return job
    }
    public func cancel(_ id: String) async throws -> CodeOvernightJob {
        guard var job = store.jobs().first(where: { $0.id == id }) else { throw CodeFailure("Unknown overnight job.") }
        if let compilation = job.compilationJobID, job.state == .building { _ = try await builds.cancel(compilation) }
        // An interrupted installer cannot safely be called a cancelled install.
        let uncertain = job.state == .installing || job.needsInstallReconciliation
        installProcesses[id]?.cancel(); workers[id]?.cancel()
        job.state = uncertain ? .unknownCompletion : .cancelled
        if let i = job.installs.indices.last, job.installs[i].state == .installing {
            job.installs[i].state = .unknownCompletion; job.installs[i].endedAt = Date()
        }
        job.revision += 1; try store.save(job)
        return job
    }
    private func recover() async throws {
        guard !recovered else { return }; recovered = true
        do {
            for var job in store.jobs() {
                if job.state == .installing {
                    job.state = .unknownCompletion
                    if let i = job.installs.indices.last { job.installs[i].state = .unknownCompletion; job.installs[i].endedAt = Date() }
                    job.error = CodeOvernightError(.interrupted, stage: "install", recovery: "The Mac restarted during installation. Refresh to reconcile the installed revision.")
                    job.revision += 1; try store.save(job)
                } else if [.accepted, .building].contains(job.state) {
                    if let id = job.compilationJobID, let build = try? await builds.status(id), let artifact = build.artifact {
                        job.artifact = artifact; job.builtAt = artifact.createdAt; job.state = .waitingForPhone
                    } else {
                        job.state = .failed
                        job.error = CodeOvernightError(.interrupted, stage: "build", recovery: "The Mac restarted before this build completed. Try again.")
                    }
                    job.revision += 1; try store.save(job)
                }
            }
        } catch { recovered = false; throw error }
    }
    private func compile(_ id: String) async {
        defer { workers[id] = nil }
        guard var job = store.jobs().first(where: { $0.id == id }) else { return }
        do {
            let protected = Set(store.jobs().filter { $0.hasActionableArtifact || $0.needsInstallReconciliation }.compactMap { $0.artifact?.id })
            try artifacts.prune(protecting: protected)
            var request = CodeRequest(.runOnDevice); request.id = "overnight-compile-" + job.id; request.project = job.target.project
            var options = CodeDeviceBuild(branch: job.target.branch, deviceID: job.target.deviceID)
            options.installOnly = true; options.artifactTarget = job.target; request.deviceBuild = options
            let compilation = try await builds.start(request)
            job.compilationJobID = compilation.id; job.state = .building; job.revision += 1; try store.save(job)
            while true {
                try Task.checkCancellation()
                let build = try await builds.status(compilation.id)
                if build.state != .running {
                    guard build.state == .succeeded, let artifact = build.artifact else { throw CodeFailure(build.failureMessage ?? "The Mac couldn’t finish this build.") }
                    guard let current = store.jobs().first(where: { $0.id == id }), current.state != .cancelled else { return }
                    job = current; job.artifact = artifact; job.builtAt = artifact.createdAt; job.state = .waitingForPhone
                    job.revision += 1; try store.save(job)
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            await install(id)
        } catch {
            guard var current = store.jobs().first(where: { $0.id == id }), current.state != .cancelled else { return }
            current.state = error is CancellationError ? .cancelled : .failed
            current.error = CodeOvernightError(error is CancellationError ? .cancelled : .build, stage: "build", recovery: error.localizedDescription)
            current.revision += 1; try? store.save(current)
        }
    }
    private func install(_ id: String) async {
        // While compiling, the worker owns this entry. A retry worker releases
        // its entry here as well. No caller holds the phone's background task.
        defer { workers[id] = nil }
        do {
            while installBusy { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(250)) }
            try Task.checkCancellation()
            guard var job = store.jobs().first(where: { $0.id == id }), job.state != .cancelled, let artifact = job.artifact else { return }
            installBusy = true; defer { installBusy = false }
            let process = CodeProcess(); installProcesses[id] = process; defer { installProcesses[id] = nil }
            let app: URL
            do { app = try await artifacts.validate(artifact, process: process) }
            catch {
                guard let latest = store.jobs().first(where: { $0.id == id }), latest.state != .cancelled else { return }
                job = latest
                job.state = .failed; job.error = CodeOvernightError(.integrity, stage: "artifact", recovery: error.localizedDescription)
                job.revision += 1; try store.save(job); return
            }
            try Task.checkCancellation()
            guard let latest = store.jobs().first(where: { $0.id == id }), latest.state != .cancelled else { return }
            job = latest
            var attempt = CodeInstallAttempt(artifactID: artifact.id, provider: .native)
            job.installs.append(attempt); job.state = .installing; job.revision += 1
            try store.save(job) // Persist intent before install or self-replacement.
            let attemptID = attempt.id
            let result = await installer.install(artifact, app: app, process: process) { [weak self] route in
                try await self?.recordRoute(route, jobID: id, attemptID: attemptID)
            }
            guard var current = store.jobs().first(where: { $0.id == id }) else { return }
            if let saved = current.installs.first(where: { $0.id == attempt.id }) { attempt = saved }
            attempt.state = result.state; attempt.error = result.error; attempt.connectionDescription = result.connectionDescription; attempt.endedAt = Date()
            if let i = current.installs.firstIndex(where: { $0.id == attempt.id }) { current.installs[i] = attempt }
            current.error = result.error
            switch result.state {
            case .succeeded: current.state = .succeeded; current.installedAt = Date()
            case .waitingForPhone: current.state = .waitingForPhone
            case .unknownCompletion, .installing: current.state = .unknownCompletion
            case .failed: current.state = .failed
            case .cancelled: current.state = .cancelled
            }
            current.revision += 1; try store.save(current)
        } catch {
            try? store.event(CodeOvernightDiagnosticEvent(stage: "installPersistence", correlationID: id, outcome: "failed"))
        }
    }
    private func recordRoute(_ route: CodeInstallRoute, jobID: String, attemptID: String) throws {
        try Task.checkCancellation()
        guard var job = store.jobs().first(where: { $0.id == jobID }), job.state == .installing,
              let i = job.installs.firstIndex(where: { $0.id == attemptID }) else { throw CancellationError() }
        job.installs[i].provider = route.provider; job.installs[i].sessionID = route.sessionID
        job.installs[i].providerGeneration = route.generation; job.installs[i].connectionDescription = route.description
        job.revision += 1; try store.save(job)
        try store.event(CodeOvernightDiagnosticEvent(stage: "installer.proxy", correlationID: attemptID, outcome: route.provider.rawValue + ".prepared"))
    }
    static func canReplaceFailedArtifact(_ job: CodeOvernightJob) -> Bool {
        job.state == .failed && job.error?.kind == .integrity && !job.needsInstallReconciliation
    }
    private static func sameDestination(_ a: CodeOvernightTarget, _ b: CodeOvernightTarget) -> Bool {
        a.peerID == b.peerID && a.deviceID == b.deviceID && a.project.path == b.project.path && a.project.scheme == b.project.scheme
    }
}
