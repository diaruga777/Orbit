import XCTest
import OrbitCore

final class CodeLocalRefreshTests: XCTestCase {
    func testDueBeforeExpiryAndBackoffWithoutRepeatingUncertainInstall() {
        let now = Date()
        var app = CodeLocalRefreshApp(name: "App", bundleID: "test.app", teamID: "TEAM", version: "1", build: "2", expiresAt: now.addingTimeInterval(36 * 3600))
        XCTAssertFalse(app.isDue(at: now))
        app.automatic = true
        XCTAssertTrue(app.isDue(at: now))
        app.lastAttempt = now
        XCTAssertFalse(app.isDue(at: now))
        XCTAssertTrue(app.isDue(at: now.addingTimeInterval(3601)))
        app.state = .installing
        XCTAssertFalse(app.isDue(at: now.addingTimeInterval(7200)))
        XCTAssertTrue(app.requiresReconciliation)
        app.state = .unknown
        XCTAssertFalse(app.isDue(at: now.addingTimeInterval(7200)))
    }
    func testConfirmationRequiresSameBuildAndEveryNewProfileIncludingExtensions() throws {
        let now = Date(), expiry = Date().addingTimeInterval(7 * 86400)
        var app = CodeLocalRefreshApp(name: "App", bundleID: "test.app", teamID: "TEAM", version: "1", build: "2", expiresAt: now)
        app.state = .installing; app.pendingProfiles = ["main-profile": expiry, "extension-profile": expiry]
        XCTAssertThrowsError(try app.confirm(version: "1", build: "3", installedProfiles: app.pendingProfiles, at: now))
        XCTAssertThrowsError(try app.confirm(version: "1", build: "2", installedProfiles: ["main-profile": expiry], at: now))
        try app.confirm(version: "1", build: "2", installedProfiles: app.pendingProfiles, at: now)
        XCTAssertEqual(app.state, .confirmed)
        XCTAssertEqual(app.expiresAt, expiry)
        XCTAssertEqual(app.lastConfirmed, now)
    }
    func testJournalSurvivesRestartAndRetainsUncertainInstall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeLocalRefreshStore(root: root)
        var app = CodeLocalRefreshApp(name: "App", bundleID: "test.app", teamID: "TEAM", version: "1", build: "2", expiresAt: Date())
        app.state = .installing; app.pendingProfiles = ["new": Date().addingTimeInterval(86400)]
        try store.save(app)
        XCTAssertEqual(try CodeLocalRefreshStore(root: root).apps(), [app])
        XCTAssertThrowsError(try store.remove(app.id))
        XCTAssertThrowsError(try store.directory("../outside"))
    }
}
