import XCTest
@testable import OrbitCore
@testable import OrbitMac

final class CodeJobProgressTests: XCTestCase {
    func testElapsedTimeDoesNotAdvanceUnmeasuredWork() {
        let start = Date(timeIntervalSince1970: 100)
        let progress = CodeJobProgress(stage: "Compile", start: 0.25, end: 0.80, estimatedSeconds: 240, startedAt: start)
        XCTAssertEqual(progress.fraction(at: start), 0.25)
        XCTAssertEqual(progress.fraction(at: start.addingTimeInterval(120)), 0.25)
        XCTAssertEqual(progress.fraction(at: start.addingTimeInterval(1_000_000)), 0.25)
        XCTAssertEqual(progress.fraction(at: start.addingTimeInterval(-100)), 0.25)
    }
    func testOnlySuccessReachesOneHundredAndFailureFreezes() {
        var job = CodeJob(id: "job", title: "Build")
        let start = Date(timeIntervalSince1970: 100)
        job.progress = CodeJobProgress(stage: "Install", start: 0.80, end: 0.93, estimatedSeconds: 40, startedAt: start)
        job.progress?.stoppedAt = start.addingTimeInterval(20)
        job.state = .failed
        XCTAssertEqual(job.progressFraction(at: start.addingTimeInterval(100)), job.progressFraction(at: start.addingTimeInterval(1000)))
        XCTAssertLessThan(job.progressFraction(), 1)
        job.state = .cancelled
        XCTAssertLessThan(job.progressFraction(), 1)
        job.state = .succeeded
        XCTAssertEqual(job.progressFraction(), 1)
    }
    func testOldCompanionJobDecodesWithoutProgress() throws {
        let data = Data(#"{"id":"old","title":"Build","state":"running","log":"","startedAt":100}"#.utf8)
        let job = try JSONDecoder().decode(CodeJob.self, from: data)
        XCTAssertNil(job.progress)
        XCTAssertEqual(job.progressFraction(at: job.startedAt), 0.05)
        let fractions = [2.0, 10, 30, 60, 120, 600].map { job.progressFraction(at: job.startedAt.addingTimeInterval($0)) }
        XCTAssertTrue(fractions.allSatisfy { $0 == 0.05 })
        XCTAssertEqual(job.progressSummary, "Waiting for build updates…")
    }
    func testMissingProgressRepliesRetainLastSnapshotWithoutInventingWork() {
        let start = Date(timeIntervalSince1970: 100)
        var reply = CodeJob(id: "legacy", title: "Build")
        reply.startedAt = start
        let initial = reply.estimatingProgress(at: start)
        let refreshed = reply.estimatingProgress(from: initial, at: start.addingTimeInterval(30))
        XCTAssertEqual(refreshed.progress, initial.progress)
        XCTAssertEqual(refreshed.progressFraction(at: start.addingTimeInterval(30)), initial.progressFraction(at: start))
        reply.state = .failed
        let failed = reply.estimatingProgress(from: refreshed, at: start.addingTimeInterval(40))
        XCTAssertEqual(failed.progressFraction(), 0.05)
        XCTAssertEqual(failed.progressFraction(at: start.addingTimeInterval(50)), failed.progressFraction(at: start.addingTimeInterval(500)))
        reply.state = .cancelled
        let cancelled = reply.estimatingProgress(from: failed, at: start.addingTimeInterval(60))
        XCTAssertEqual(cancelled.progress, failed.progress)
        reply.state = .succeeded
        XCTAssertEqual(reply.estimatingProgress(from: refreshed).progressFraction(), 1)
    }
    func testClockSkewDoesNotInventWork() {
        let received = Date(timeIntervalSince1970: 100)
        var reply = CodeJob(id: "legacy", title: "Build")
        reply.startedAt = received.addingTimeInterval(3600)
        let initial = reply.estimatingProgress(at: received)
        let refreshed = reply.estimatingProgress(from: initial, at: received.addingTimeInterval(10))
        XCTAssertEqual(refreshed.progressFraction(at: received.addingTimeInterval(10)), 0.05)
        var other = reply; other.id = "another"
        XCTAssertEqual(other.estimatingProgress(from: initial, at: received.addingTimeInterval(10)).progress?.startedAt, received.addingTimeInterval(10))
    }
    func testStagesAndFrozenProgressSurviveWireRoundTrip() throws {
        var job = CodeJob(id: "job", title: "Build")
        job.progress = CodeJobProgress(stage: "Checkout", start: 0.10, end: 0.15, estimatedSeconds: 20)
        job.progress?.stoppedAt = Date()
        XCTAssertEqual(job, try JSONDecoder().decode(CodeJob.self, from: JSONEncoder().encode(job)))
    }
    func testRestartFreezesInterruptedProgressAndRetainsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var job = CodeJob(id: "interrupted", title: "Build")
        job.progress = CodeJobProgress(stage: "Compile", start: 0.25, end: 0.80, estimatedSeconds: 240)
        try JSONEncoder().encode(job).write(to: root.appendingPathComponent(job.id + ".json"))
        let jobs = try CodeJobs(root: root)
        let restored = try await jobs.status(job.id)
        XCTAssertEqual(restored.state, .failed)
        XCTAssertNotNil(restored.progress?.stoppedAt)
        XCTAssertTrue(restored.failureMessage?.contains("restarted") == true)
    }
}
