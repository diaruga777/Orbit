import XCTest
import UIKit

final class OrbitOptionalSetupUITests: XCTestCase {
    func testPairingLinkAsksBeforeSavingMac() {
        let app = XCUIApplication()
        app.launchArguments = ["--optional-setup-fixture", "none", "--reset-connection"]
        let code = URL(string: "orbit://pair?device=" + String(repeating: "A", count: 52))!
        app.open(code)
        let confirmation = app.alerts["Connect to this Mac?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(app.cells.containing(.staticText, identifier: "Connect a Mac").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Forget Mac"].exists)
        app.open(code)
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.buttons["Cancel"].tap()
    }
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
        app.navigationBars.buttons["Setup details"].tap()
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
            // UIKit draws this badge but exposes an empty accessibility value.
            // Check the rendered tab item, including the badge, in all four states.
            XCTAssertEqual(hasRedBadge(more.screenshot().image), !refresh || !remote)
            XCTAssertFalse(app.buttons["Dismiss setup banner"].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "More setup - \(fixture)"; screenshot.lifetime = .keepAlways; add(screenshot)
            app.terminate()
        }
    }
    private func hasRedBadge(_ image: UIImage) -> Bool {
        guard let image = image.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let redPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 180 && pixels[$0 + 1] < 125 && pixels[$0 + 2] < 150 && pixels[$0 + 3] > 200
        }.count
        return redPixels > 20
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
        XCTAssertTrue(app.alerts["Remote builds"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote connections are set up.")).firstMatch.exists)
        app.alerts.buttons["View Mac Connection"].tap()
        XCTAssertTrue(app.navigationBars["Orbit Mac"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.cells["settings.remote"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.cells["settings.remote"].value as? String, "Ready")
        XCTAssertEqual(app.cells["settings.refresh"].value as? String, "Setup needed")
    }
}
