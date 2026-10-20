#if os(iOS)
import UIKit
import BackgroundTasks
import OrbitCore

/// Owns the startup lease and job polling independently of the selected tab or modal.
@MainActor public final class CodeBuildMonitor {
    static let changed = Notification.Name("CodeBuildMonitor.changed")
    private let client: CodeClient
    private let defaults: UserDefaults
    private let peerID: () -> String
    private var peer = ""
    private var timer: Timer?
    private var polling = false
    private var acknowledgingInstall = false
    private var installLease: UIBackgroundTaskIdentifier = .invalid
    private var lease: UIBackgroundTaskIdentifier = .invalid
    private var continued: BGContinuedProcessingTask?
    private var requested = false
    private var startingAt: Date?
    private var title = "Build"
    private var disconnected = false
    private var reportedFraction = 0.0
    private var monitoringStopped = false
    public private(set) var job: CodeJob?
    public private(set) var isStarting = false
    public var becameIdle: (() -> Void)?
    private var handoffKey: String { "Code.installHandoff." + peer }
    private var didHandOff: Bool { job.map { defaults.string(forKey: handoffKey) == $0.id } ?? false }
    public var needsConnection: Bool { isStarting || acknowledgingInstall || (job?.state == .running && !monitoringStopped && !didHandOff) }
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "org.example.orbit.ios") + ".remote-build" }
    var fraction: Double { reportedFraction }
    func fraction(for value: CodeJob) -> Double { job?.id == value.id ? fraction : value.progressFraction() }
    var stage: String { isStarting ? "Starting on your Mac…" : (job?.progressStage ?? "Build") }
    var backgroundMessage: String {
        if isStarting { return "Keep Orbit open while the build starts." }
        if let handoff = job?.installHandoff {
            return handoff.acknowledged
                ? "Installing the update. Orbit may close and reopen."
                : "Keep Orbit open until the update starts installing."
        }
        if disconnected { return "Reconnecting… Your Mac can keep building while you wait." }
        if monitoringStopped || !requested {
            return "You can leave Orbit. Come back to check progress."
        }
        return "You can leave Orbit while your Mac builds."
    }

    init(client: CodeClient, defaults: UserDefaults, peerID: @escaping () -> String) {
        self.client = client; self.defaults = defaults; self.peerID = peerID
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                guard let self else { task.setTaskCompleted(success: false); return }
                if self.didHandOff || self.job?.installHandoff != nil {
                    task.updateTitle("Build complete", subtitle: "Updating Orbit…")
                    task.progress.totalUnitCount = 1000; task.progress.completedUnitCount = 1000
                    task.setTaskCompleted(success: true); return
                }
                guard self.needsConnection else { task.setTaskCompleted(success: false); return }
                self.continued = task
                task.progress.totalUnitCount = 1000
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in self?.stopBackgroundMonitoring() }
                }
                self.publish()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(activated), name: UIApplication.didBecomeActiveNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }
    deinit { timer?.invalidate() }

    func begin(title: String) throws {
        guard !isStarting, job?.state != .running else { throw CodeFailure("A build is already running. Wait for it or cancel it first.") }
        self.title = title; peer = peerID(); job = nil; reportedFraction = 0; isStarting = true; startingAt = Date()
        monitoringStopped = false; disconnected = false
        defaults.removeObject(forKey: handoffKey)
        lease = UIApplication.shared.beginBackgroundTask(withName: "Start remote build") { [weak self] in
            Task { @MainActor in self?.endLease() }
        }
        requestBackgroundMonitoring()
        publish()
    }
    func endStarting(peer origin: String) {
        guard peer == origin else { return }
        isStarting = false; endLease()
        if job == nil { complete(success: false) }
        publish()
    }
    func accept(_ received: CodeJob) {
        guard peer == peerID() else { return }
        // A late status reply must not resurrect a completed job.
        if job?.id == received.id, job?.state != .running, received.state == .running { return }
        let value = received.estimatingProgress(from: job)
        CodeBuildCatalog(defaults: defaults).record(value, peer: peer)
        if job?.id != value.id { reportedFraction = 0 }
        job = value; isStarting = false; disconnected = false
        defaults.set(value.id, forKey: "Code.activeJob." + peer)
        endLease(); publish()
        if value.state != .running { complete(success: value.state == .succeeded) }
        else if value.installHandoff != nil { prepareForInstall(value) }
    }
    /// Reattach status monitoring without starting another Mac build.
    func observe(_ value: CodeJob) {
        guard !isStarting else { return }
        if job?.id == value.id, peer == peerID() { accept(value) }
        else if job?.state != .running, value.state == .running {
            peer = peerID(); job = nil; title = value.title; monitoringStopped = false
            if value.shouldMonitorInBackground, defaults.string(forKey: handoffKey) != value.id, UIApplication.shared.applicationState == .active { requestBackgroundMonitoring() }
            accept(value)
        }
    }
    private func requestBackgroundMonitoring() {
        guard UIApplication.shared.applicationState == .active else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Starting on your Mac…")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request); requested = true }
        catch { requested = false }
    }
    @objc private func activated() {
        if peer != peerID() { job = nil; isStarting = false; complete(success: false); peer = peerID() }
        monitoringStopped = false
        if job?.shouldMonitorInBackground == true, !requested, !didHandOff { requestBackgroundMonitoring() }
        Task {
            let origin = peerID(), key = "Code.activeJob." + peerID()
            if job == nil, let id = defaults.string(forKey: key) {
                var request = CodeRequest(.job); request.jobID = id
                if let value = try? await client.call(request).job, origin == peerID() {
                    if value.state != .running, defaults.string(forKey: key) == id { defaults.removeObject(forKey: key) }
                    observe(value)
                }
            }
            await tick()
        }
    }
    private func tick() async {
        guard peer == peerID(), needsConnection || (UIApplication.shared.applicationState == .active && job?.state == .running) else { return }
        // Keep the system activity honest while the Mac is unreachable.
        if !disconnected { publish() }
        guard let job, job.state == .running, !polling,
              UIApplication.shared.applicationState == .active || continued != nil || acknowledgingInstall else { return }
        polling = true; defer { polling = false }
        let origin = peer
        var request = CodeRequest(.job); request.jobID = job.id
        do {
            guard let value = try await client.call(request).job else { throw CodeFailure("The Mac returned no build status.") }
            guard origin == peerID(), self.job?.id == value.id else { return }
            accept(value)
        } catch {
            guard origin == peerID(), self.job?.id == job.id else { return }
            disconnected = true
            continued?.updateTitle(title, subtitle: "Mac unreachable · progress paused")
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    private func publish() {
        if !disconnected {
            let estimate = job?.progressFraction() ?? min(0.04, 0.01 + max(0, Date().timeIntervalSince(startingAt ?? Date())) / 2000)
            reportedFraction = max(reportedFraction, estimate)
            continued?.progress.completedUnitCount = Int64((fraction * 1000).rounded(.down))
            let detail = job?.progressDetail.map { $0 + " · " } ?? ""
            continued?.updateTitle(title, subtitle: String("\(Int(fraction * 100))% estimated · \(detail)\(stage)".prefix(180)))
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    private func prepareForInstall(_ value: CodeJob) {
        guard let handoff = value.installHandoff else { return }
        let origin = peer, id = value.id
        // Persist before acknowledging. Relaunch must never create another
        // continued-processing activity for the installation that replaces us.
        defaults.set(id, forKey: handoffKey)
        continued?.updateTitle("Build complete", subtitle: "Updating Orbit…")
        continued?.progress.completedUnitCount = continued?.progress.totalUnitCount ?? 1000
        continued?.setTaskCompleted(success: true); continued = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier); requested = false
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
        continued?.setTaskCompleted(success: false); continued = nil; requested = false
        endLease(); publish(); becameIdle?()
    }
    private func complete(success: Bool) {
        continued?.setTaskCompleted(success: success); continued = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier); requested = false
        endLease()
        if job?.state != .running { defaults.removeObject(forKey: "Code.activeJob." + peer); defaults.removeObject(forKey: handoffKey) }
        becameIdle?()
    }
}
#endif
