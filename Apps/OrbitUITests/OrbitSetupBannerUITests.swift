import XCTest

final class OrbitSetupBannerUITests: XCTestCase {
    func testOptionalSetupRoutesAndDismissalSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-extra-setup"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Take Orbit with you"].waitForExistence(timeout: 10))
        app.buttons["Phone-only refresh"].tap()
        XCTAssertTrue(app.tabBars.buttons["Refresh"].isSelected)
        app.buttons["Remote builds"].tap()
        XCTAssertTrue(app.alerts["Build away from home"].waitForExistence(timeout: 5))
        app.alerts.buttons["Open Mac Tab"].tap()
        XCTAssertTrue(app.tabBars.buttons["Mac"].isSelected)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Optional setup banner"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Dismiss setup banner"].tap()
        XCTAssertFalse(app.staticTexts["Take Orbit with you"].exists)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Mac"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Take Orbit with you"].exists)
    }
}
