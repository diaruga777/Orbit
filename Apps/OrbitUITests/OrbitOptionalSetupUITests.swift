import XCTest

final class OrbitOptionalSetupUITests: XCTestCase {
    func testDeliveredExpiryNotificationOpensSetupAfterTermination() {
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = ["--expiry-reminder-fixture", "--reset-connection"]
        app.launch()
        if springboard.buttons["Allow"].waitForExistence(timeout: 5) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
        app.terminate()
        let notification = springboard.staticTexts["Finish phone-only refresh"].firstMatch
        XCTAssertTrue(notification.waitForExistence(timeout: 30))
        notification.tap()
        XCTAssertTrue(app.navigationBars["Refresh"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Apple Account"].exists)
        app.terminate(); app.launchArguments = []; app.launch()
    }
    func testExpiryNotificationOpensSetupWithDismissedBannerOnColdLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--open-expiry-notification", "--reset-connection"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Refresh"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Apple Account"].exists)
        XCTAssertTrue(app.staticTexts["Cache Orbit"].exists)
        XCTAssertFalse(app.staticTexts["Take Orbit with you"].exists)
    }
    func testSetupRowsBadgeIndependentlyAndMoreBadgesEitherIncompleteSetup() {
        let app = XCUIApplication()
        for (fixture, refresh, remote) in [("none", false, false), ("remote", false, true), ("refresh", true, false), ("both", true, true)] {
            app.launchArguments = ["--optional-setup-fixture", fixture, "--reset-connection"]
            app.launch()
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
            let refreshRow = app.cells["settings.refresh"]
            let remoteRow = app.cells["settings.remote"]
            XCTAssertTrue(refreshRow.waitForExistence(timeout: 5))
            XCTAssertEqual(refreshRow.value as? String, refresh ? "Ready" : "Setup needed")
            XCTAssertEqual(remoteRow.value as? String, remote ? "Ready" : "Setup needed")
            let more = app.tabBars.buttons["More"]
            XCTAssertEqual(more.value as? String, (!refresh || !remote) ? "!" : nil)
            XCTAssertFalse(app.buttons["Dismiss setup banner"].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "More setup - \(fixture)"; screenshot.lifetime = .keepAlways; add(screenshot)
            app.terminate()
        }
    }
    func testSetupRowsRemainAvailableAndRouteToExistingFlowsAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--optional-setup-fixture", "remote", "--reset-connection"]
        app.launch()
        XCTAssertTrue(app.cells["settings.refresh"].waitForExistence(timeout: 10))
        app.cells["settings.refresh"].tap()
        XCTAssertTrue(app.navigationBars["Refresh"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["More"].tap()
        app.cells["settings.remote"].tap()
        XCTAssertTrue(app.alerts["Build away from home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote connections are set up.")).firstMatch.exists)
        app.alerts.buttons["Open Mac Settings"].tap()
        XCTAssertTrue(app.navigationBars["Orbit Mac"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.cells["settings.remote"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.cells["settings.remote"].value as? String, "Ready")
        XCTAssertEqual(app.cells["settings.refresh"].value as? String, "Setup needed")
    }
}
