import XCTest
import OrbitCore
@testable import OrbitMac

final class CodeExpiryReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func app(_ bundle: String = "test.app", days: Double = 7, device: String = "phone") -> CodeInstalledApp {
        CodeInstalledApp(deviceID: device, bundleID: bundle, name: bundle, version: "1", build: "2",
            installedAt: now, profileExpiresAt: now.addingTimeInterval(days * 86400))
    }
    func testEarliestExpiryWinsAndSchedulesExactly24HoursAhead() throws {
        let apps = [app("paid", days: 365), app("free"), app("extension", days: 3)]
        let plan = try XCTUnwrap(CodeExpiryReminder.next(apps: apps, setupComplete: false, at: now))
        XCTAssertEqual(plan.app.bundleID, "extension")
        XCTAssertEqual(plan.scheduledAt, now.addingTimeInterval(2 * 86400))
        XCTAssertNil(CodeExpiryReminder.next(apps: apps, setupComplete: true, at: now))
        XCTAssertNil(CodeExpiryReminder.next(apps: [], setupComplete: false, at: now))
    }
    func testActualPaidExpiryAndSevenDayFallbackSurviveWireRoundTrip() throws {
        var fallback = app(); fallback.profileExpiresAt = nil
        let decoded = try JSONDecoder().decode(CodeInstalledApp.self, from: JSONEncoder().encode(fallback))
        XCTAssertEqual(decoded.expiresAt, now.addingTimeInterval(7 * 86400))
        let paid = try XCTUnwrap(CodeExpiryReminder.next(apps: [app(days: 365)], setupComplete: false, at: now))
        XCTAssertEqual(paid.scheduledAt, now.addingTimeInterval(364 * 86400))
        // Provisioning is measured from issuance; an older profile may expire
        // sooner than seven days after this installation.
        let shorter = try XCTUnwrap(CodeExpiryReminder.next(apps: [app(days: 2)], setupComplete: false, at: now))
        XCTAssertEqual(shorter.scheduledAt, now.addingTimeInterval(86400))
    }
    func testLateSyncAndExpiredEvidence() throws {
        let soon = app(days: 0.5)
        let plan = try XCTUnwrap(CodeExpiryReminder.next(apps: [app("expired", days: -1), soon], setupComplete: false, at: now))
        XCTAssertLessThan(plan.scheduledAt, now) // Delivery catches up immediately.
        XCTAssertEqual(plan.app, soon)
        XCTAssertNil(CodeExpiryReminder.next(apps: [app(days: -1)], setupComplete: false, at: now))
    }
    func testConfirmedRenewalReplacesOlderExpiryAndKeepsOtherApps() throws {
        let original = app("first", days: 1), other = app("second", days: 2)
        var renewed = app("first", days: 8); renewed.installedAt = now.addingTimeInterval(1)
        let latest = CodeExpiryReminder.latest([renewed, other, original])
        XCTAssertEqual(latest.count, 2)
        XCTAssertEqual(CodeExpiryReminder.next(apps: latest, setupComplete: false, at: now)?.app.bundleID, "second")
        XCTAssertNotEqual(CodeExpiryReminder.next(apps: [original], setupComplete: false, at: now)?.key,
                          CodeExpiryReminder.next(apps: [renewed], setupComplete: false, at: now)?.key)
    }
    func testInstallationJournalPersistsAndScopesSnapshotRemovalToOnePhone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeInstalledAppStore(root: root)
        let first = app(), other = app(device: "other-phone")
        try store.record(first); try store.record(other)
        var renewed = app(days: 365); renewed.installedAt = now.addingTimeInterval(1)
        try store.record(renewed); try store.record(first)
        XCTAssertEqual(try CodeInstalledAppStore(root: root).apps().count, 2)
        XCTAssertEqual(try store.apps().first(where: { $0.deviceID == "phone" }), renewed)
        try store.replace(deviceID: "phone", with: [])
        XCTAssertEqual(try store.apps(), [other])
    }
    func testLegacyArtifactsDecodeWithoutExpiryAndBuildsDoNotProveInstallation() throws {
        let target = CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: CodeProject(path: "/App.xcodeproj", scheme: "App"), branch: "main", generation: "1")
        var artifact = CodeBuildArtifact(id: UUID().uuidString, jobID: "job", target: target, bundleID: "app", version: "1", build: "2", commit: "abc", digest: "digest", signingAuthority: "team", byteCount: 1)
        let legacy = try JSONDecoder().decode(CodeBuildArtifact.self, from: JSONEncoder().encode(artifact))
        XCTAssertNil(legacy.profileExpiresAt)
        artifact.profileExpiresAt = now.addingTimeInterval(365 * 86400)
        XCTAssertEqual(try JSONDecoder().decode(CodeBuildArtifact.self, from: JSONEncoder().encode(artifact)).profileExpiresAt, artifact.profileExpiresAt)
        let job = CodeJob(id: "job", title: "Built", state: .succeeded)
        XCTAssertNil(try JSONDecoder().decode(CodeJob.self, from: JSONEncoder().encode(job)).installation)
    }
    func testRetainedInstallBackfillsRPCButUnconfirmedBuildsAreExcluded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeOvernightStore(root: root.appendingPathComponent("Overnight"))
        let target = CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: CodeProject(path: "/App.xcodeproj", scheme: "App"), branch: "main", generation: "1")
        var job = CodeOvernightJob(requestID: "request", invocationID: "invocation", target: target)
        job.artifact = CodeBuildArtifact(id: UUID().uuidString, jobID: job.id, target: target, bundleID: "app", version: "1", build: "2", commit: "abc", digest: "digest", signingAuthority: "team", byteCount: 1)
        job.state = .waitingForPhone
        try store.save(job)
        let service = try CodeService(root: root)
        let before = try await service.installedApps()
        XCTAssertTrue(before.isEmpty)
        job.state = .succeeded; job.installedAt = now; job.artifact?.profileExpiresAt = now.addingTimeInterval(365 * 86400)
        try store.save(job)
        let restarted = try CodeService(root: root)
        let apps = try await restarted.installedApps()
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.installedAt, now)
        XCTAssertEqual(apps.first?.profileExpiresAt, job.artifact?.profileExpiresAt)
    }
}
