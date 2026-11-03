#if os(iOS)
import UIKit
import BackgroundTasks
import OrbitCore

/// Owns the startup lease and job polling independently of the selected tab or modal.
@MainActor public final class CodeBuildMonitor {
    public static let changed = Notification.Name("CodeBuildMonitor.changed")
    private let client: CodeClient
    private let status: ((String) async throws -> CodeJob)?
    private let defaults: UserDefaults
    private let peerID: () -> String
    private var peer = ""
    private var timer: Timer?
    private var polling = false
    private var acknowledgingInstall = false
    private var installLease: UIBackgroundTaskIdentifier = .invalid
    private var lease: UIBackgroundTaskIdentifier = .invalid
    private var continued: (any CodeBuildBackgroundTask)?
    private let background: any CodeBuildBackgroundScheduling
    private let isActive: @MainActor () -> Bool
    private var requested = false
    private var title = "Build"
    private var disconnected = false
    private var reportedFraction = 0.0
    private var monitoringStopped = false
    public private(set) var job: CodeJob?
    public private(set) var isStarting = false
    public var becameIdle: (() -> Void)?
    private var activityKey: String { "Code.backgroundJob." + peer }
    private var handoffKey: String { "Code.installHandoff." + peer }
    private var didHandOff: Bool { job.map { defaults.string(forKey: handoffKey) == $0.id } ?? false }
    public var needsConnection: Bool { isStarting || acknowledgingInstall || (job?.state == .running && !monitoringStopped && !didHandOff) }
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "org.example.orbit.ios") + ".remote-build" }
    public var fraction: Double { reportedFraction }
    public func fraction(for value: CodeJob) -> Double { job?.id == value.id ? fraction : value.progressFraction() }
    public var stage: String { isStarting ? "Starting on your Mac…" : (job?.progressStage ?? "Build") }
    public var backgroundMessage: String {
        if isStarting { return "Keep Orbit open while the build starts." }
        if let handoff = job?.installHandoff {
            return handoff.acknowledged
                ? "Installing the update. Orbit may close."
                : "Keep Orbit open until the update starts installing."
        }
        if let message = job?.failureMessage { return message }
        if disconnected { return "Reconnecting… Your Mac can keep building while you wait." }
        if monitoringStopped || !requested {
            return "You can leave Orbit. Come back to check progress."
        }
        return "You can leave Orbit while your Mac builds."
    }

    init(client: CodeClient, defaults: UserDefaults, peerID: @escaping () -> String, status: ((String) async throws -> CodeJob)? = nil, background: (any CodeBuildBackgroundScheduling)? = nil, isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }, pollAutomatically: Bool = true) {
        self.status = status; self.client = client; self.defaults = defaults; self.peerID = peerID
        self.background = background ?? CodeBuildSystemScheduler(); self.isActive = isActive
        self.background.register(identifier: identifier) { [weak self] task in
            guard let self else { task.setTaskCompleted(success: false); return }
            let handoff = self.didHandOff || self.job?.installHandoff != nil
            if handoff || self.job?.state == .succeeded {
                self.finish(task, success: true, handoff: handoff); return
            }
            guard self.job?.shouldMonitorInBackground == true, !self.monitoringStopped else {
                self.finish(task, success: false); return
            }
            self.continued = task
            OrbitDiagnostics.shared.record("build_activity", "started", ["job": self.job?.id ?? ""])
            task.expirationHandler = { [weak self, weak task] in
                Task { @MainActor in
                    guard let self, let task, self.continued === task else { return }
                    self.stopBackgroundMonitoring()
                }
            }
            self.publish()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(activated), name: UIApplication.didBecomeActiveNotification, object: nil)
        if pollAutomatically { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        } }
    }
    deinit { timer?.invalidate() }

    public func begin(title: String) throws {
        guard !isStarting, job?.state != .running else { throw CodeFailure("A build is already running. Wait for it or cancel it first.") }
        self.title = title; peer = peerID(); job = nil; reportedFraction = 0; isStarting = true
        monitoringStopped = false; disconnected = false
        defaults.removeObject(forKey: handoffKey)
        lease = UIApplication.shared.beginBackgroundTask(withName: "Start remote build") { [weak self] in
            Task { @MainActor in self?.endLease() }
        }
        publish()
    }
    public func endStarting(peer origin: String) {
        guard peer == origin else { return }
        isStarting = false; endLease()
        if job == nil { complete(success: false) }
        publish()
    }
    public func accept(_ received: CodeJob) {
        guard peer == peerID() else { return }
        // A late status reply must not resurrect a completed job.
        if job?.id == received.id, job?.state != .running, received.state == .running { return }
        let value = received.estimatingProgress(from: job)
        CodeBuildCatalog(defaults: defaults).record(value, peer: peer)
        if job?.id != value.id {
            reportedFraction = 0
            monitoringStopped = defaults.string(forKey: activityKey) == value.id
        }
        job = value; isStarting = false; disconnected = false
        defaults.set(value.id, forKey: "Code.activeJob." + peer)
        endLease()
        if value.shouldMonitorInBackground { requestBackgroundMonitoring() }
        publish()
        if value.state != .running { complete(success: value.state == .succeeded) }
        else if value.installHandoff != nil { prepareForInstall(value) }
    }
    /// Reattach status monitoring without starting another Mac build.
    public func observe(_ value: CodeJob) {
        guard !isStarting else { return }
        if job?.id == value.id, peer == peerID() { accept(value) }
        else if job?.state != .running, value.state == .running {
            peer = peerID(); job = nil; title = value.title; monitoringStopped = false
            accept(value)
        }
    }
    private func requestBackgroundMonitoring() {
        guard isActive(), !requested, !monitoringStopped, !didHandOff,
              let job, job.shouldMonitorInBackground,
              defaults.string(forKey: activityKey) != job.id else { return }
        // A system expiration/dismissal ends this job's monitoring attempt. Neither
        // catalog polls nor foreground/relaunch may create another system activity.
        defaults.set(job.id, forKey: activityKey)
        do {
            try background.submit(identifier: identifier, title: title); requested = true
            OrbitDiagnostics.shared.record("build_activity", "submitted", ["job": job.id])
        } catch {
            requested = false; monitoringStopped = true
            OrbitDiagnostics.shared.error("build_activity", "submission_failed", error, ["job": job.id])
        }
    }
    @objc public func activated() {
        if peer != peerID() { job = nil; isStarting = false; complete(success: false); peer = peerID() }
        requestBackgroundMonitoring()
        Task {
            let origin = peerID(), key = "Code.activeJob." + peerID()
            if job == nil, let id = defaults.string(forKey: key) {
                if let value = try? await loadStatus(id), origin == peerID() {
                    if value.state != .running, defaults.string(forKey: key) == id { defaults.removeObject(forKey: key) }
                    observe(value)
                }
            }
            await tick()
        }
    }
    private func tick() async {
        guard peer == peerID(), needsConnection || (isActive() && job?.state == .running) else { return }
        // Keep the system activity honest while the Mac is unreachable.
        if !disconnected { publish() }
        guard let job, job.state == .running, !polling,
              isActive() || continued != nil || acknowledgingInstall else { return }
        polling = true; defer { polling = false }
        let origin = peer
        do {
            let value = try await loadStatus(job.id)
            guard origin == peerID(), self.job?.id == value.id else { return }
            accept(value)
        } catch {
            guard origin == peerID(), self.job?.id == job.id else { return }
            disconnected = true
            continued?.updateTitle(title, subtitle: "Mac unreachable · progress paused")
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    private func loadStatus(_ id: String) async throws -> CodeJob {
        if let status { return try await status(id) }
        var request = CodeRequest(.job); request.jobID = id
        guard let job = try await client.call(request).job else { throw CodeFailure("The Mac returned no build status.") }
        return job
    }
    public func show(_ value: CodeJob, from controller: UIViewController, console: Bool = false) {
        observe(value)
        controller.present(UINavigationController(rootViewController: CodeLogController(job: value, showConsole: console, monitor: self)), animated: true)
    }
    private func publish() {
        if !disconnected {
            reportedFraction = job?.progressFraction() ?? 0
            // An unknown denominator is indeterminate, including in the system activity.
            continued?.progress.totalUnitCount = job?.state == .succeeded ? 1 : -1
            continued?.progress.completedUnitCount = job?.state == .succeeded ? 1 : Int64(job?.progress?.completedTasks ?? 0)
            let detail = job?.progressDetail.map { $0 + " · " } ?? ""
            continued?.updateTitle(title, subtitle: String("\(detail)\(stage)".prefix(180)))
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    private func prepareForInstall(_ value: CodeJob) {
        guard let handoff = value.installHandoff else { return }
        let origin = peer, id = value.id
        // Persist before acknowledging. Relaunch must never create another
        // continued-processing activity for the installation that replaces us.
        defaults.set(id, forKey: handoffKey)
        if let continued { finish(continued, success: true, handoff: true) }; continued = nil
        background.cancel(identifier: identifier); requested = false
        if handoff.acknowledged { if !acknowledgingInstall { becameIdle?() }; return }
        guard !acknowledgingInstall else { return }
        acknowledgingInstall = true
        installLease = UIApplication.shared.beginBackgroundTask(withName: "Acknowledge Orbit update") { [weak self] in
            Task { @MainActor in self?.endInstallLease() }
        }
        Task {
            defer { acknowledgingInstall = false; endInstallLease(); becameIdle?() }
            var request = CodeRequest(.acknowledgeInstall); request.jobID = id; request.handoffToken = handoff.token
            do {
                guard let reply = try await client.call(request).job else { throw CodeFailure("Couldn’t start installing the update. Reconnect to your Mac and try again.") }
                guard origin == peerID(), job?.id == id else { return }
                accept(reply)
            } catch {
                guard origin == peerID(), job?.id == id else { return }
                disconnected = true
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
        }
    }
    private func endInstallLease() {
        if installLease != .invalid { UIApplication.shared.endBackgroundTask(installLease); installLease = .invalid }
    }
    private func endLease() {
        if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
    }
    private func stopBackgroundMonitoring() {
        // Expiration may mean system resource pressure or user dismissal. The Mac
        // owns accepted work; stopping phone monitoring must not kill that build.
        monitoringStopped = true
        OrbitDiagnostics.shared.record("build_activity", "expired", ["job": job?.id ?? ""])
        if let continued { finish(continued, success: false) }; continued = nil; requested = false
        endLease(); publish(); becameIdle?()
    }
    private func finish(_ task: any CodeBuildBackgroundTask, success: Bool, handoff: Bool = false) {
        task.expirationHandler = nil
        if success {
            if handoff { task.updateTitle("Build complete", subtitle: "Updating Orbit…") }
            // Running progress has an unknown total. Never complete it with -1 units.
            task.progress.totalUnitCount = 1; task.progress.completedUnitCount = 1
        }
        task.setTaskCompleted(success: success)
        OrbitDiagnostics.shared.record("build_activity", "finished", ["job": job?.id ?? "", "success": String(success)])
    }
    private func complete(success: Bool) {
        if let continued { finish(continued, success: success) }; continued = nil
        background.cancel(identifier: identifier); requested = false
        endLease()
        if job?.state != .running { defaults.removeObject(forKey: "Code.activeJob." + peer); defaults.removeObject(forKey: handoffKey) }
        becameIdle?()
    }
}
#endif
