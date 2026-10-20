#if os(iOS)
import UIKit
import BackgroundTasks
import OrbitCore

@MainActor public final class CodeNightlyScheduler {
    public static let shared = CodeNightlyScheduler()
    private let defaults = UserDefaults.standard
    private var perform: ((CodeOvernightInvocation, Bool) async throws -> [CodeOvernightJob])?
    public private(set) var journal: CodeOvernightStore?
    private var active: Task<Void, Never>?
    private var activeID: String?
    public private(set) var nextRequestedAt: Date?
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "org.example.orbit.ios") + ".overnight-builds" }
    public func register(journal: CodeOvernightStore, perform: @escaping (CodeOvernightInvocation, Bool) async throws -> [CodeOvernightJob]) {
        self.journal = journal; self.perform = perform
        try? journal.reconcileInterruptedInvocations()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            Task { @MainActor in
                guard let self, let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
                // Record the actual wake before scheduling, connecting or checking policy.
                var invocation = self.invocation(reason: "background")
                do { try journal.save(invocation) }
                catch { task.setTaskCompleted(success: false); return }
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date().addingTimeInterval(86400)
                self.schedule(after: tomorrow)
                invocation.nextRequestedAt = self.nextRequestedAt
                guard self.active == nil else {
                    invocation.state = .skipped; invocation.endedAt = Date()
                    invocation.error = CodeOvernightError(.unsupported, stage: "coordinator", recovery: "Another attempt is already running.")
                    try? journal.save(invocation); task.setTaskCompleted(success: true); return
                }
                self.activeID = invocation.id
                let completion = CodeBackgroundCompletion(task: task)
                let work = Task { @MainActor in
                    let success = await self.execute(invocation, manual: false)
                    if self.activeID == invocation.id { self.active = nil; self.activeID = nil }
                    completion.finish(success)
                }
                self.active = work
                let started = invocation
                task.expirationHandler = {
                    work.cancel()
                    Task { @MainActor in
                        var expired = started; expired.state = .expired; expired.endedAt = Date()
                        expired.controlProvider = journal.invocations().first(where: { $0.id == started.id })?.controlProvider
                        expired.error = CodeOvernightError(.interrupted, stage: "runtime", recovery: "iOS ended this attempt. Accepted builds continue on your Mac.")
                        try? journal.save(expired)
                        if self.activeID == started.id { self.active = nil; self.activeID = nil }
                        completion.finish(false)
                    }
                }
            }
        }
        try? journal.event(CodeOvernightDiagnosticEvent(stage: "registration", correlationID: identifier, outcome: registered ? "registered" : "failed"))
        schedule()
    }
    public func policy(peer: String) -> CodeOvernightPolicy {
        if let data = defaults.data(forKey: "Code.overnightPolicy." + peer), let policy = try? JSONDecoder().decode(CodeOvernightPolicy.self, from: data) { return policy }
        let policy = CodeOvernightPolicy(); setPolicy(policy, peer: peer); return policy
    }
    public func setPolicy(_ policy: CodeOvernightPolicy, peer: String) {
        let key = "Code.overnightPolicy." + peer
        if let previous = defaults.data(forKey: key), let old = try? JSONDecoder().decode(CodeOvernightPolicy.self, from: previous), old != policy { active?.cancel() }
        defaults.set(try? JSONEncoder().encode(policy), forKey: key)
    }
    public func tryNow() {
        guard active == nil else { return }
        let invocation = invocation(reason: "foreground")
        do { try journal?.save(invocation) } catch { return }
        activeID = invocation.id
        active = Task { [weak self] in
            _ = await self?.execute(invocation, manual: true)
            if self?.activeID == invocation.id { self?.active = nil; self?.activeID = nil }
        }
    }
    private func invocation(reason: String) -> CodeOvernightInvocation {
        var invocation = CodeOvernightInvocation(reason: reason, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        invocation.peerID = defaults.string(forKey: "Code.nightlyPeer")
        invocation.scheduledFor = defaults.object(forKey: "Code.nextOvernightDate") as? Date
        return invocation
    }
    private func execute(_ original: CodeOvernightInvocation, manual: Bool) async -> Bool {
        var invocation = original
        do {
            guard let peer = defaults.string(forKey: "Code.nightlyPeer"),
                  CodeBuildCatalog(defaults: defaults).apps(peer: peer).contains(where: { $0.nightlyEnabled == true }) else {
                invocation.state = .skipped; invocation.error = CodeOvernightError(.unsupported, stage: "policy", recovery: "No apps have overnight builds enabled.")
                invocation.endedAt = Date(); try journal?.save(invocation); return true
            }
            guard manual || CodeNightlySchedule.isOvernight(Date()) else {
                invocation.state = .skipped; invocation.error = CodeOvernightError(.unsupported, stage: "window", recovery: "This wake was outside the overnight window.")
                invocation.endedAt = Date(); try journal?.save(invocation); return true
            }
            guard let perform else { throw CodeFailure("Overnight builds are not configured.") }
            let jobs = try await perform(invocation, manual)
            try Task.checkCancellation()
            invocation.controlProvider = journal?.invocations().first(where: { $0.id == invocation.id })?.controlProvider
            invocation.jobIDs = jobs.map(\.id)
            invocation.state = jobs.contains(where: { $0.invocationID == invocation.id }) ? .accepted : .succeeded
            invocation.endedAt = Date(); try journal?.save(invocation)
            return true
        } catch let skip as CodeOvernightSkip {
            invocation.state = .skipped; invocation.endedAt = Date()
            invocation.error = CodeOvernightError(.transport, stage: skip.stage, recovery: skip.message)
            try? journal?.save(invocation); return true
        } catch {
            invocation.state = Task.isCancelled ? .expired : .failed
            invocation.error = CodeOvernightError(Task.isCancelled ? .interrupted : .transport, stage: "connection", recovery: error.localizedDescription, domain: (error as NSError).domain, code: (error as NSError).code)
            invocation.endedAt = Date(); try? journal?.save(invocation)
            return false
        }
    }
    public func schedule(peer: String? = nil, after date: Date = Date()) {
        if let peer { defaults.set(peer, forKey: "Code.nightlyPeer") }
        guard let peer = defaults.string(forKey: "Code.nightlyPeer"),
              CodeBuildCatalog(defaults: defaults).apps(peer: peer).contains(where: { $0.nightlyEnabled == true }) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            nextRequestedAt = nil; defaults.removeObject(forKey: "Code.nextOvernightDate"); return
        }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = false; request.requiresNetworkConnectivity = false
        request.earliestBeginDate = CodeNightlySchedule.nextStart(after: date)
        do {
            try BGTaskScheduler.shared.submit(request)
            nextRequestedAt = request.earliestBeginDate; defaults.set(nextRequestedAt, forKey: "Code.nextOvernightDate")
            try? journal?.event(CodeOvernightDiagnosticEvent(stage: "schedule", correlationID: identifier, outcome: "submitted"))
        } catch {
            nextRequestedAt = nil; defaults.removeObject(forKey: "Code.nextOvernightDate")
            try? journal?.event(CodeOvernightDiagnosticEvent(stage: "schedule", correlationID: identifier, outcome: "submissionFailed"))
        }
    }
}
@MainActor private final class CodeBackgroundCompletion {
    private var task: BGTask?
    init(task: BGTask) { self.task = task }
    func finish(_ success: Bool) {
        guard let task else { return }; self.task = nil
        task.expirationHandler = nil; task.setTaskCompleted(success: success)
    }
}
#endif
