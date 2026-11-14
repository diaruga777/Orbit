import XCTest
@testable import OrbitCore
@testable import OrbitMac

final class CodeOvernightJobsTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func target() -> CodeOvernightTarget {
        CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: CodeProject(path: "/App.xcodeproj", scheme: "App"), branch: "main", generation: "g")
    }
    private func artifact(_ target: CodeOvernightTarget) -> CodeBuildArtifact {
        CodeBuildArtifact(id: UUID().uuidString, jobID: "compile", target: target, bundleID: "com.example.fixture", version: "1.0", build: "42", commit: "abc", digest: "digest", signingAuthority: "team", byteCount: 32)
    }
    func testRetainedSelfUpdateAcknowledgementPersistsAcrossRestart() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeOvernightStore(root: directory.appendingPathComponent("Overnight"))
        var ready = CodeOvernightJob(requestID: "self-update", invocationID: "phone", target: target())
        ready.state = .waitingForPhone; ready.artifact = artifact(target())
        ready.monitorBundleID = ready.artifact?.bundleID; ready.installHandoff = CodeInstallHandoff()
        try store.save(ready)
        let builds = try CodeJobs(root: directory.appendingPathComponent("Jobs"))
        let service = try CodeOvernightService(root: directory, builds: builds)
        do { _ = try await service.acknowledgeInstall(ready.id, token: "wrong"); XCTFail("Wrong token released update") } catch { }
        XCTAssertEqual(store.jobs().first?.installHandoff?.acknowledged, false)
        let acknowledged = try await service.acknowledgeInstall(ready.id, token: ready.installHandoff?.token)
        XCTAssertEqual(acknowledged?.installHandoff?.acknowledged, true)
        XCTAssertEqual(acknowledged?.state, .running)
        XCTAssertEqual(try CodeOvernightStore(root: directory.appendingPathComponent("Overnight")).jobs().first?.installHandoff?.acknowledged, true)
        let restored = try CodeOvernightService(root: directory, builds: builds)
        let repeated = try await restored.acknowledgeInstall(ready.id, token: ready.installHandoff?.token)
        XCTAssertEqual(repeated?.installHandoff, acknowledged?.installHandoff)
        XCTAssertEqual(repeated?.state, .running, "Acknowledgement does not prove installation")
        let unknown = try await restored.acknowledgeInstall("direct-job", token: "token")
        XCTAssertNil(unknown, "Direct jobs must continue to use the original build gate")
    }
    func testAcceptedAndInterruptedInstallsReconcileWithoutRecreatingProcesses() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeOvernightStore(root: directory.appendingPathComponent("Overnight"))
        var accepted = CodeOvernightJob(requestID: "first", invocationID: "wake", target: target())
        try store.save(accepted)
        var installing = CodeOvernightJob(requestID: "second", invocationID: "wake", target: target())
        installing.state = .installing; installing.artifact = artifact(target())
        installing.installs = [CodeInstallAttempt(artifactID: installing.artifact!.id, provider: .local)]
        try store.save(installing)
        let builds = try CodeJobs(root: directory.appendingPathComponent("Jobs"))
        let service = try CodeOvernightService(root: directory, builds: builds)
        let records = try await service.status()
        XCTAssertEqual(records.first(where: { $0.id == accepted.id })?.state, .failed)
        XCTAssertEqual(records.first(where: { $0.id == installing.id })?.state, .unknownCompletion)
        XCTAssertEqual(records.first(where: { $0.id == installing.id })?.installs.first?.state, .unknownCompletion)
        accepted.revision = 100 // A stale external copy is deliberately not written.
        XCTAssertEqual(try CodeOvernightStore(root: directory.appendingPathComponent("Overnight")).jobs(), records)
    }
    func testReadyArtifactWinsOverNewDayAndChangedScheduleGeneration() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeOvernightStore(root: directory.appendingPathComponent("Overnight"))
        var ready = CodeOvernightJob(requestID: "yesterday", invocationID: "old", target: target())
        ready.state = .waitingForPhone; ready.artifact = artifact(target()); try store.save(ready)
        let service = try CodeOvernightService(root: directory, builds: CodeJobs(root: directory.appendingPathComponent("Jobs")))
        var request = CodeRequest(.overnightSubmit)
        var changed = target(); changed.generation = "next-generation"; changed.branch = "updated"
        request.overnight = CodeOvernightSubmission(invocationID: "new", target: changed, localDay: "tomorrow")
        let response = try await service.submit(request)
        XCTAssertEqual(response.id, ready.id)
        XCTAssertEqual(response.artifact, ready.artifact)
        let status = try await service.status(); XCTAssertEqual(status.count, 1)
    }
    func testLostAcknowledgmentSurvivesRestartAndRejectsReusedTarget() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeOvernightStore(root: directory.appendingPathComponent("Overnight"))
        let accepted = CodeOvernightJob(requestID: "stable", invocationID: "old-wake", target: target())
        try store.save(accepted)
        let service = try CodeOvernightService(root: directory, builds: CodeJobs(root: directory.appendingPathComponent("Jobs")))
        var request = CodeRequest(.overnightSubmit); request.id = "stable"
        request.overnight = CodeOvernightSubmission(invocationID: "new-wake", target: target(), localDay: "today")
        let response = try await service.submit(request); XCTAssertEqual(response.id, accepted.id)
        request.overnight?.target.deviceID = "other-phone"
        do { _ = try await service.submit(request); XCTFail("Target changes cannot reuse an operation") } catch {}
    }
    func testCancellationKeepsUncertainInstallEvidence() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeOvernightStore(root: directory.appendingPathComponent("Overnight"))
        var job = CodeOvernightJob(requestID: "stable", invocationID: "wake", target: target())
        job.state = .unknownCompletion; job.artifact = artifact(target())
        try store.save(job)
        let service = try CodeOvernightService(root: directory, builds: CodeJobs(root: directory.appendingPathComponent("Jobs")))
        let result = try await service.cancel(job.id)
        XCTAssertEqual(result.state, .unknownCompletion); XCTAssertEqual(result.artifact, job.artifact)
    }
    func testInstallationReadbackRequiresBothVersionAndBuildOnExactBundle() {
        let artifact = artifact(target())
        let match: [String: Any] = ["result": ["apps": [["bundleIdentifier": artifact.bundleID, "version": "1.0", "bundleVersion": "42"]]]]
        XCTAssertTrue(CodeNativeInstaller.matchesReadback(match, artifact: artifact))
        for app in [["bundleIdentifier": artifact.bundleID], ["bundleIdentifier": artifact.bundleID, "version": "1.0", "bundleVersion": "41"], ["bundleIdentifier": "other", "version": "1.0", "bundleVersion": "42"]] {
            XCTAssertFalse(CodeNativeInstaller.matchesReadback(["result": ["apps": [app]]], artifact: artifact))
        }
    }
    func testTransportFallbackClassificationRejectsSigningPairingAndLockFailures() {
        for (message, expected) in [("device is locked", CodeOvernightError.Kind.locked), ("invalid provisioning profile", .signing), ("pairing authentication failed", .pairing), ("device is not connected", .transport), ("unexpected installer error", .unknown)] {
            XCTAssertEqual(CodeNativeInstaller.classify(["error": ["description": message]]), expected)
        }
    }
    func testRetryChangesLegacyFailedArtifactToWaitingBeforeReturningIt() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeOvernightStore(root: directory.appendingPathComponent("Overnight"))
        var job = CodeOvernightJob(requestID: "legacy", invocationID: "phone", target: target())
        job.state = .failed
        job.artifact = artifact(job.target)
        job.error = CodeOvernightError(.pairing, stage: "install", recovery: "Check trust.", domain: "com.apple.dt.CoreDeviceError", code: 4016)
        try store.save(job)
        let builds = try CodeJobs(root: directory.appendingPathComponent("Jobs"))
        let service = try CodeOvernightService(root: directory, builds: builds, journal: store)
        let retry = try await service.retryInstall(job.id)
        XCTAssertEqual(retry.id, job.id)
        XCTAssertEqual(retry.artifact, job.artifact)
        XCTAssertEqual(retry.state, .waitingForPhone)
        XCTAssertNil(retry.error)
        // This fixture deliberately has no app on disk, so the worker can
        // finish without reaching the installer or touching a phone.
        let deadline = ContinuousClock.now + .seconds(3)
        while store.jobs().first?.state == .waitingForPhone && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.jobs().first?.error?.kind, .integrity)
    }
    func testCoreDeviceUnavailableWaitsBeforeHandoffAndReconcilesAfterHandoff() throws {
        let domain = "com.apple.dt.CoreDeviceError"
        let document: [String: Any] = ["error": ["domain": domain, "code": 4016, "userInfo": [
            "CurrentlyAssertableStates": ["array": []],
            "RequestedDeviceStates": ["array": [["string": "com.apple.coredevice.remoteServiceDiscoveryTrustedConnectivityAvailable"]]]
        ]]]
        let kind = CodeNativeInstaller.classify(document)
        XCTAssertEqual(kind, .transport)
        let before = CodeNativeInstaller.commandFailure(kind, stage: "before", domain: domain, code: 4016)
        XCTAssertEqual(before.state, .waitingForPhone)
        XCTAssertTrue(try XCTUnwrap(before.error?.recovery).contains("Xcode version"))
        let install = CodeNativeInstaller.commandFailure(kind, stage: "install", domain: domain, code: 4016)
        XCTAssertEqual(install.state, .unknownCompletion)
        let readback = CodeNativeInstaller.commandFailure(.locked, stage: "readback", domain: domain, code: 1)
        XCTAssertEqual(readback.state, .unknownCompletion)
    }
    func testArtifactDigestDetectsMutationAndRejectsEscapingSymlink() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("binary")
        try Data("first".utf8).write(to: file)
        let before = try CodeArtifactStore.digest(directory)
        try Data("other".utf8).write(to: file)
        XCTAssertNotEqual(before.0, try CodeArtifactStore.digest(directory).0)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertThrowsError(try CodeArtifactStore.digest(directory))
    }
    func testArtifactIdentifiersCannotEscapeStore() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeArtifactStore(root: directory)
        XCTAssertThrowsError(try store.appURL("../../elsewhere"))
    }
    func testDurableAcceptanceFailsClosedOnDiskError() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = try CodeOvernightService(root: directory, builds: CodeJobs(root: directory.appendingPathComponent("Jobs")))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Overnight/attempts-v1.json"), withIntermediateDirectories: true)
        var request = CodeRequest(.overnightSubmit)
        request.overnight = CodeOvernightSubmission(invocationID: "wake", target: target(), localDay: "today")
        do { _ = try await service.submit(request); XCTFail("Cannot acknowledge unpersisted work") } catch {}
    }
    func testScheduledCompilationNeverLaunchesApp() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/OrbitMac/CodeNativeInstaller.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("\"process\", \"launch\""))
        XCTAssertTrue(text.contains("\"install\", \"app\""))
    }
}
