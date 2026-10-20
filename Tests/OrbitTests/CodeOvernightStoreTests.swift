import XCTest
@testable import OrbitCore

final class CodeOvernightStoreTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func job() -> CodeOvernightJob {
        CodeOvernightJob(requestID: "request", invocationID: "wake", target: CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: CodeProject(path: "/private/source/App.xcodeproj", scheme: "App"), branch: "main", generation: "generation"))
    }
    func testRestartMarksOnlyUnfinishedInvocationsUnknown() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeOvernightStore(root: directory)
        let started = CodeOvernightInvocation(reason: "background")
        var finished = CodeOvernightInvocation(reason: "foreground"); finished.state = .accepted; finished.endedAt = Date()
        try store.save(started); try store.save(finished)
        let restored = try CodeOvernightStore(root: directory)
        try restored.reconcileInterruptedInvocations()
        XCTAssertEqual(restored.invocations().first?.state, .unknownCompletion)
        XCTAssertEqual(restored.invocations().last?.state, .accepted)
        var stale = started; stale.state = .succeeded
        try restored.save(stale)
        XCTAssertEqual(restored.invocations().first?.state, .unknownCompletion)
    }
    func testRevisionMergeAndSyncNeverDowngradeTerminalResult() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeOvernightStore(root: directory)
        var current = job(); current.state = .succeeded; current.installedAt = Date(); current.revision = 4
        try store.save(current)
        var stale = current; stale.state = .installing; stale.revision = 3
        try store.save(stale); XCTAssertEqual(store.jobs().first?.state, .succeeded)
        stale.revision = 4
        try store.save(stale); XCTAssertEqual(store.jobs().first?.state, .succeeded)
        current.synchronizedAt = Date()
        try store.save(current); XCTAssertEqual(store.jobs().first?.synchronizedAt, current.synchronizedAt)
        XCTAssertEqual(try CodeOvernightStore(root: directory).jobs(), store.jobs())
    }
    func testCorruptionAndFutureSchemaDoNotSilentlyResetHistory() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeOvernightStore(root: directory); try store.save(job())
        let file = directory.appendingPathComponent("attempts-v1.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json["version"] = 99; try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertThrowsError(try CodeOvernightStore(root: directory))
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try CodeOvernightStore(root: directory))
    }
    func testExportRedactsIdentityAndSourcePathsAndMarksMissingMac() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodeOvernightStore(root: directory)
        try store.save(job())
        let export = try store.export(remote: nil, capabilities: CodeOvernightCapabilities())
        let local = try String(contentsOf: export.appendingPathComponent("local.json"), encoding: .utf8)
        XCTAssertFalse(local.contains("/private/source")); XCTAssertFalse(local.contains("\"phone\"")); XCTAssertFalse(local.contains("\"request\""))
        let manifest = try String(contentsOf: export.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("unavailable"))
    }
    func testSameLocalDateAcrossTimeZoneChangesHasSameOperationID() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var sydney = utc; sydney.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let date = ISO8601DateFormatter().date(from: "2026-10-20T02:00:00Z")!
        let app = CodeBuildApp(project: CodeProject(path: "/App.xcodeproj", scheme: "App"), name: "App", bundleID: "app")
        XCTAssertEqual(CodeNightlySchedule.requestID(app: app, peer: "mac", date: date, calendar: utc), CodeNightlySchedule.requestID(app: app, peer: "mac", date: date, calendar: sydney))
    }
}
