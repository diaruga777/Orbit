import XCTest
import OrbitCore
@testable import OrbitUI

@MainActor final class CodeBuildMonitorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        super.setUp()
        suite = "OrbitMonitorTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    private func monitor(_ scheduler: Scheduler, peer: @escaping () -> String = { "mac" }) -> CodeBuildMonitor {
        CodeBuildMonitor(client: CodeClient { _ in throw CodeFailure("No transport in this test") },
            defaults: defaults, peerID: peer, background: scheduler, isActive: { true }, pollAutomatically: false)
    }
    private func expire(_ task: BackgroundTask) async throws {
        let completed = expectation(description: "Expiration finishes the monitoring task")
        task.onComplete = { completed.fulfill() }
        try XCTUnwrap(task.expirationHandler)()
        await fulfillment(of: [completed], timeout: 3)
    }

    func testActivityCountsObservedWorkThroughCompilationAndInstallation() {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        var job = CodeJob(id: "reader", title: "Build & Install · Reader")
        job.progress = CodeJobProgress(stage: "Compiling", start: 0.1, end: 0.7, estimatedSeconds: 100)
        job.progress?.activeTasks = 4
        monitor.observe(job)
        let task = scheduler.launch()
        let initialFraction = task.progress.fractionCompleted
        job.progress?.completedTasks = 3
        job.progress?.activeTasks = 1
        monitor.accept(job)
        let compiling = task.progress.completedUnitCount
        XCTAssertGreaterThan(task.progress.fractionCompleted, initialFraction)
        monitor.accept(job)
        XCTAssertEqual(task.progress.completedUnitCount, compiling)
        job.builtAt = Date()
        job.progress = CodeJobProgress(stage: "Installing", start: 0.8, end: 0.93, estimatedSeconds: 40)
        monitor.accept(job)
        XCTAssertGreaterThan(task.progress.completedUnitCount, compiling)
        XCTAssertLessThan(task.progress.fractionCompleted, 1)
        job.state = .succeeded
        job.includesLocalChanges = true
        monitor.accept(job)
        XCTAssertEqual(task.title, "Build completed")
        XCTAssertEqual(task.subtitle, "Includes uncommitted changes.")
        XCTAssertEqual(task.progress.fractionCompleted, 1)
        XCTAssertEqual(scheduler.cancellations, 0)
    }

    func testExpirationReconcilesTheMacResultWhileBackgrounded() async throws {
        for state in [CodeJob.State.succeeded, .failed, .cancelled] {
            let scheduler = Scheduler()
            var foreground = true
            let monitor = CodeBuildMonitor(client: CodeClient { _ in throw CodeFailure("Unexpected request") },
                defaults: defaults, peerID: { "mac" }, status: { id in
                    CodeJob(id: id, title: "Build", state: state)
                }, background: scheduler, isActive: { foreground }, pollAutomatically: false)
            monitor.observe(CodeJob(id: state.rawValue, title: "Build"))
            let task = scheduler.launch()
            foreground = false
            try await expire(task)
            XCTAssertEqual(task.completions, [state == .succeeded])
            XCTAssertEqual(task.title, state == .succeeded ? "Build completed" : state == .failed ? "Build failed" : "Build cancelled")
            XCTAssertEqual(monitor.job?.state, state)
        }
    }

    func testUnresponsiveStatusReadCannotHoldExpiredTaskOpen() async throws {
        var reply: CheckedContinuation<CodeJob, Never>?
        let scheduler = Scheduler()
        let monitor = CodeBuildMonitor(client: CodeClient { _ in throw CodeFailure("Unexpected request") },
            defaults: defaults, peerID: { "mac" }, status: { _ in await withCheckedContinuation { reply = $0 } },
            background: scheduler, isActive: { true }, pollAutomatically: false)
        let job = CodeJob(id: "slow", title: "Build")
        monitor.observe(job)
        let task = scheduler.launch()
        try await expire(task)
        XCTAssertEqual(task.title, "Check build in Orbit")
        XCTAssertEqual(monitor.job?.state, .running)
        let successor = CodeJob(id: job.id, title: job.title, state: .succeeded)
        try XCTUnwrap(reply).resume(returning: successor)
        await Task.yield()
        XCTAssertEqual(task.completions, [true])
    }

    func testStartupCreatesNoActivityUntilTheMacAcceptsAJob() throws {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        try monitor.begin(title: "Build Orbit")
        XCTAssertEqual(scheduler.submissions, 0)
        monitor.activated() // Foreground notifications during a slow start.
        XCTAssertEqual(scheduler.submissions, 0)
        monitor.accept(CodeJob(id: "accepted", title: "Build Orbit"))
        monitor.endStarting(peer: "mac")
        monitor.observe(CodeJob(id: "accepted", title: "Build Orbit"))
        monitor.activated()
        XCTAssertEqual(scheduler.submissions, 1)
        XCTAssertTrue(monitor.needsConnection)
    }
    func testInterruptedStartupCanReattachWithoutAFailedStartupActivity() throws {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        try monitor.begin(title: "Build Orbit")
        monitor.endStarting(peer: "mac")
        XCTAssertEqual(scheduler.submissions, 0)
        // The Mac accepted the request, but its reply was lost.
        monitor.observe(CodeJob(id: "accepted", title: "Build Orbit"))
        XCTAssertEqual(scheduler.submissions, 1)
        let task = scheduler.launch()
        XCTAssertTrue(task.completions.isEmpty)
        XCTAssertEqual(monitor.job?.state, .running)
    }
    func testExpirationDoesNotRestartActivityOnPollingForegroundOrRelaunch() async throws {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        let job = CodeJob(id: "running", title: "Build Orbit")
        monitor.observe(job)
        let task = scheduler.launch()
        try await expire(task)
        XCTAssertEqual(task.completions, [true], "Ending phone monitoring must not announce a failed Mac build")
        XCTAssertEqual(task.title, "Check build in Orbit")
        XCTAssertEqual(task.subtitle, "Your Mac has the latest status.")
        XCTAssertNil(task.expirationHandler)
        for _ in 0..<3 { monitor.activated(); monitor.observe(job) }
        XCTAssertEqual(scheduler.submissions, 1)
        XCTAssertEqual(monitor.job?.state, .running, "Only the monitor expired; the Mac build is still running")
        let restoredScheduler = Scheduler(), restored = self.monitor(restoredScheduler)
        restored.observe(job)
        restored.activated()
        XCTAssertEqual(restoredScheduler.submissions, 0)
        XCTAssertEqual(restored.job?.state, .running)
        XCTAssertTrue(restored.backgroundMessage.contains("Come back to check progress"))
    }
    func testConfirmedInstallAfterExpirationDoesNotLeaveAFailedActivityOrRestartMonitoring() async throws {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        var job = CodeJob(id: "reader", title: "Build & Install · LunaReader")
        job.builtAt = Date()
        job.progress = CodeJobProgress(stage: "Installing on your phone…", start: 0.80, end: 0.93, estimatedSeconds: 40)
        monitor.observe(job)
        let task = scheduler.launch()
        try await expire(task)
        XCTAssertEqual(monitor.job?.state, .running)
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(task.title, "App built")
        job.state = .succeeded; monitor.accept(job)
        XCTAssertEqual(monitor.job?.state, .succeeded)
        XCTAssertEqual(monitor.fraction, 1)
        XCTAssertEqual(scheduler.submissions, 1)
        XCTAssertEqual(task.completions, [true], "An expired task must only complete once")
    }
    func testConfirmedSuccessReplacesTheLastInstallingStageInActivity() {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        var job = CodeJob(id: "reader", title: "Build & Install · LunaReader")
        job.builtAt = Date()
        job.progress = CodeJobProgress(stage: "Installing on your phone…", start: 0.80, end: 0.93, estimatedSeconds: 40)
        monitor.observe(job)
        let task = scheduler.launch()
        job.state = .succeeded; monitor.accept(job)
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(task.title, "Build completed")
        XCTAssertEqual(task.progress.fractionCompleted, 1)
    }
    func testLateFailedJobWithAnOldHandoffIsStillAFailure() {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        var job = CodeJob(id: "self", title: "Build Orbit")
        monitor.observe(job)
        job.state = .failed; job.installHandoff = CodeInstallHandoff(acknowledged: true)
        monitor.accept(job)
        let task = scheduler.launch()
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(task.title, "Build failed")
    }
    func testRejectedSubmissionIsNotRetriedByStatusPolls() {
        let scheduler = Scheduler(); scheduler.reject = true
        let monitor = monitor(scheduler), job = CodeJob(id: "running", title: "Build")
        monitor.observe(job)
        for _ in 0..<3 { monitor.activated(); monitor.observe(job) }
        XCTAssertEqual(scheduler.submissions, 1)
        XCTAssertEqual(monitor.job?.state, .running)
    }
    func testLateLaunchAfterConfirmedSuccessCompletesSuccessfully() {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        var job = CodeJob(id: "fast", title: "Build")
        monitor.observe(job)
        job.state = .succeeded; monitor.accept(job)
        let task = scheduler.launch()
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(task.progress.fractionCompleted, 1)
    }
    func testSelfInstallFinishesUnknownProgressBeforeAcknowledgementAndNeverRestarts() async {
        let scheduler = Scheduler()
        var task: BackgroundTask!
        let monitor = CodeBuildMonitor(client: CodeClient { _ in
            await MainActor.run {
                XCTAssertEqual(task.completions, [true])
                XCTAssertEqual(task.progress.fractionCompleted, 1)
            }
            throw CodeFailure("Lost acknowledgement reply")
        }, defaults: defaults, peerID: { "mac" }, background: scheduler, isActive: { true }, pollAutomatically: false)
        var job = CodeJob(id: "self", title: "Build Orbit")
        monitor.observe(job); task = scheduler.launch()
        XCTAssertLessThan(task.progress.fractionCompleted, 1)
        job.installHandoff = CodeInstallHandoff()
        monitor.accept(job)
        XCTAssertEqual(task.completions, [true])
        XCTAssertNil(task.expirationHandler)
        await Task.yield()
        monitor.activated(); monitor.observe(job)
        XCTAssertEqual(scheduler.submissions, 1)
        XCTAssertEqual(monitor.job?.state, .running, "Handoff is not confirmed installation")
        let restoredScheduler = Scheduler(), restored = self.monitor(restoredScheduler)
        restored.observe(job); restored.activated()
        XCTAssertEqual(restoredScheduler.submissions, 0)
    }
    func testSelfInstallBeforeSchedulerLaunchCompletesLateActivitySuccessfully() {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        var job = CodeJob(id: "self", title: "Build Orbit")
        monitor.observe(job)
        job.installHandoff = CodeInstallHandoff(acknowledged: true)
        monitor.accept(job)
        let task = scheduler.launch()
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(task.progress.fractionCompleted, 1)
        XCTAssertNil(task.expirationHandler)
        monitor.activated(); monitor.observe(job)
        XCTAssertEqual(scheduler.submissions, 1)
        XCTAssertEqual(monitor.job?.state, .running)
    }
    func testOldExpirationCannotFailTheNextBuildAndActualFailureIsPreserved() async throws {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        var first = CodeJob(id: "one", title: "Build")
        monitor.observe(first)
        let oldTask = scheduler.launch(), oldExpiration = oldTask.expirationHandler
        first.state = .succeeded; monitor.accept(first)
        try monitor.begin(title: "Build again")
        var next = CodeJob(id: "two", title: "Build again")
        monitor.accept(next)
        let currentTask = scheduler.launch()
        oldExpiration?(); await Task.yield()
        XCTAssertTrue(currentTask.completions.isEmpty)
        XCTAssertEqual(scheduler.submissions, 2)
        next.state = .failed; monitor.accept(next)
        XCTAssertEqual(currentTask.completions, [false])
        XCTAssertEqual(currentTask.title, "Build failed")
        XCTAssertEqual(oldTask.completions, [true])
        XCTAssertEqual(monitor.job?.state, .failed)
    }
    func testHandoffTimeoutExplainsRecoveryWhileRetainingTheMacJob() {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        let target = CodeOvernightTarget(peerID: "mac", deviceID: "fixture",
            project: CodeProject(path: "/Fixture/App.xcodeproj", scheme: "App"), branch: "main", generation: "fixture")
        var retained = CodeOvernightJob(requestID: "request", invocationID: "fixture", target: target)
        retained.state = .waitingForPhone
        retained.error = CodeOvernightError(.interrupted, stage: "handoff",
            recovery: "The build finished, but the update couldn’t start installing. Reopen Orbit and try the build again.")
        monitor.observe(retained.monitoring())
        XCTAssertEqual(monitor.backgroundMessage, retained.error?.recovery)
        XCTAssertEqual(monitor.job?.state, .running, "The retained artifact can still install")
    }
    func testBackgroundAttemptIsScopedToThePairedMac() {
        let scheduler = Scheduler(); var peer = "mac-one"
        let monitor = monitor(scheduler, peer: { peer })
        monitor.observe(CodeJob(id: "same-id", title: "Build"))
        let oldTask = scheduler.launch()
        peer = "mac-two"; monitor.activated()
        XCTAssertEqual(oldTask.completions, [true])
        XCTAssertEqual(oldTask.title, "Check build in Orbit")
        monitor.observe(CodeJob(id: "same-id", title: "Build"))
        XCTAssertEqual(scheduler.submissions, 2)
    }
}

@MainActor private final class Scheduler: CodeBuildBackgroundScheduling {
    var handler: (@MainActor (any CodeBuildBackgroundTask) -> Void)?
    var submissions = 0
    var cancellations = 0
    var reject = false
    func register(identifier: String, handler: @escaping @MainActor (any CodeBuildBackgroundTask) -> Void) { self.handler = handler }
    func submit(identifier: String, title: String) throws {
        submissions += 1
        if reject { throw CodeFailure("Scheduler busy") }
    }
    func cancel(identifier: String) { cancellations += 1 }
    func launch() -> BackgroundTask { let task = BackgroundTask(); handler?(task); return task }
}
@MainActor private final class BackgroundTask: CodeBuildBackgroundTask {
    let progress = Progress(totalUnitCount: 1000)
    var expirationHandler: (() -> Void)?
    var completions: [Bool] = []
    var onComplete: (() -> Void)?
    var title = ""
    var subtitle = ""
    func updateTitle(_ title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
    func setTaskCompleted(success: Bool) { completions.append(success); onComplete?() }
}
