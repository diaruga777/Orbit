import XCTest
@testable import OrbitCore
@testable import OrbitMac

private actor InstallProbe {
    var ran = false
    func install() { ran = true }
}
final class CodeInstallHandoffTests: XCTestCase {
    func testInstallationWaitsForCorrectAcknowledgementAndRetriesAreIdempotent() async throws {
        let gate = CodeInstallHandoffGate(), probe = InstallProbe()
        let handoff = await gate.prepare("job")
        let repeated = await gate.prepare("job"); XCTAssertEqual(handoff, repeated)
        let task = Task { try await gate.wait("job", timeout: 2); await probe.install() }
        try await Task.sleep(for: .milliseconds(150))
        let before = await probe.ran; XCTAssertFalse(before)
        do { _ = try await gate.acknowledge("job", token: "wrong"); XCTFail("Wrong token must not release installation") } catch {}
        let value = try await gate.acknowledge("job", token: handoff.token)
        XCTAssertTrue(value.acknowledged)
        let retried = try await gate.acknowledge("job", token: handoff.token)
        XCTAssertEqual(value, retried)
        try await task.value
        let after = await probe.ran; XCTAssertTrue(after)
    }
    func testTimeoutAndCancellationNeverReleaseInstallation() async throws {
        let gate = CodeInstallHandoffGate()
        _ = await gate.prepare("timeout")
        do { try await gate.wait("timeout", timeout: 0.05); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("update couldn’t start installing")) }
        _ = await gate.prepare("cancelled")
        let task = Task { try await gate.wait("cancelled", timeout: 2) }
        await gate.cancel("cancelled")
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testBundleMatchingAndRestoredHandoffNeverRestartBackgroundActivity() throws {
        XCTAssertFalse(CodeDeviceBuild(deviceID: "phone").requiresInstallHandoff(for: "app.code"))
        let options = CodeDeviceBuild(deviceID: "phone", monitorBundleID: "app.code")
        XCTAssertTrue(options.requiresInstallHandoff(for: "app.code"))
        XCTAssertFalse(options.requiresInstallHandoff(for: "app.other"))
        var job = CodeJob(id: "job", title: "Build")
        XCTAssertTrue(job.shouldMonitorInBackground)
        job.installHandoff = CodeInstallHandoff()
        let restored = try JSONDecoder().decode(CodeJob.self, from: JSONEncoder().encode(job))
        XCTAssertFalse(restored.shouldMonitorInBackground)
        job.installHandoff?.acknowledged = true
        XCTAssertFalse(job.shouldMonitorInBackground)
        XCTAssertEqual(job.state, .running, "Acknowledged installation is not a successful deployment yet")
        job.state = .failed
        XCTAssertFalse(job.shouldMonitorInBackground)
    }
}
