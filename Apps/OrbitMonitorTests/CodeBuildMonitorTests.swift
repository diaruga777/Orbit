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
    func testExpirationDoesNotRestartActivityOnPollingForegroundOrRelaunch() async {
        let scheduler = Scheduler(), monitor = monitor(scheduler)
        let job = CodeJob(id: "running", title: "Build Orbit")
        monitor.observe(job)
        let task = scheduler.launch()
        task.expirationHandler?()
        await Task.yield()
        XCTAssertEqual(task.completions, [false])
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
        XCTAssertEqual(task.progress.totalUnitCount, 1)
        XCTAssertEqual(task.progress.completedUnitCount, 1)
    }
    func testSelfInstallFinishesUnknownProgressBeforeAcknowledgementAndNeverRestarts() async {
        let scheduler = Scheduler()
        var task: BackgroundTask!
        let monitor = CodeBuildMonitor(client: CodeClient { _ in
            await MainActor.run {
                XCTAssertEqual(task.completions, [true])
                XCTAssertEqual(task.progress.totalUnitCount, 1)
                XCTAssertEqual(task.progress.completedUnitCount, 1)
            }
            throw CodeFailure("Lost acknowledgement reply")
        }, defaults: defaults, peerID: { "mac" }, background: scheduler, isActive: { true }, pollAutomatically: false)
        var job = CodeJob(id: "self", title: "Build Orbit")
        monitor.observe(job); task = scheduler.launch()
        XCTAssertEqual(task.progress.totalUnitCount, -1)
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
        XCTAssertEqual(oldTask.completions, [true])
        XCTAssertEqual(monitor.job?.state, .failed)
    }
    func testBackgroundAttemptIsScopedToThePairedMac() {
        let scheduler = Scheduler(); var peer = "mac-one"
        let monitor = monitor(scheduler, peer: { peer })
        monitor.observe(CodeJob(id: "same-id", title: "Build"))
        peer = "mac-two"; monitor.activated()
        monitor.observe(CodeJob(id: "same-id", title: "Build"))
        XCTAssertEqual(scheduler.submissions, 2)
    }
}

@MainActor private final class Scheduler: CodeBuildBackgroundScheduling {
    var handler: (@MainActor (any CodeBuildBackgroundTask) -> Void)?
    var submissions = 0
    var reject = false
    func register(identifier: String, handler: @escaping @MainActor (any CodeBuildBackgroundTask) -> Void) { self.handler = handler }
    func submit(identifier: String, title: String) throws {
        submissions += 1
        if reject { throw CodeFailure("Scheduler busy") }
    }
    func cancel(identifier: String) {}
    func launch() -> BackgroundTask { let task = BackgroundTask(); handler?(task); return task }
}
@MainActor private final class BackgroundTask: CodeBuildBackgroundTask {
    let progress = Progress(totalUnitCount: 1000)
    var expirationHandler: (() -> Void)?
    var completions: [Bool] = []
    func updateTitle(_ title: String, subtitle: String) {}
    func setTaskCompleted(success: Bool) { completions.append(success) }
}
