import XCTest

final class OrbitSetupBannerUITests: XCTestCase {
    func testDeliveredExpiryNotificationOpensSetupAfterTermination() {
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = ["--expiry-reminder-fixture", "--reset-connection"]
        app.launch()
        if springboard.buttons["Allow"].waitForExistence(timeout: 5) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.navigationBars["Orbit Mac"].waitForExistence(timeout: 10))
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
    func testOptionalSetupRoutesAndDismissalSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-extra-setup"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Take Orbit with you"].waitForExistence(timeout: 10))
        app.buttons["Phone-only refresh"].tap()
        XCTAssertTrue(app.navigationBars["Refresh"].waitForExistence(timeout: 5))
        app.buttons["Remote builds"].tap()
        XCTAssertTrue(app.alerts["Build away from home"].waitForExistence(timeout: 5))
        app.alerts.buttons["Open Mac Tab"].tap()
        XCTAssertTrue(app.navigationBars["Orbit Mac"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Optional setup banner"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Dismiss setup banner"].tap()
        XCTAssertFalse(app.staticTexts["Take Orbit with you"].exists)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.navigationBars["Orbit Mac"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Take Orbit with you"].exists)
    }
}
