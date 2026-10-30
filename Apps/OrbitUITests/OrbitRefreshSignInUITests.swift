import XCTest

final class OrbitRefreshSignInUITests: XCTestCase {
    private func launch(_ scenario: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--refresh-sign-in-fixture", scenario]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Apple Account"].waitForExistence(timeout: 10))
        return app
    }
    private func fill(_ app: XCUIApplication) {
        let email = app.textFields["Apple Account email"]
        email.tap(); email.typeText("person@example.test")
        let password = app.secureTextFields["Password"]
        password.tap(); password.typeText("fixture-password")
    }
    private func tap(_ button: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if button.isHittable { button.tap(); return }
            app.scrollViews["refresh-sign-in-scroll"].swipeUp()
        }
        XCTFail("Control was not reachable: \(button)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func testBlankServerAndRememberCompletesWithoutAdvanced() {
        let app = launch("remember")
        XCTAssertFalse(app.textFields["Automatic — SideStore"].exists)
        fill(app)
        tap(app.switches["Remember password"], in: app)
        tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.staticTexts["Account ready"].waitForExistence(timeout: 10))
    }
    func testValidationAndNetworkErrorsStayInFormAndRetryWorks() {
        let app = launch("retry")
        tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.staticTexts["Enter your Apple Account email."].exists)
        fill(app)
        tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.staticTexts["Couldn’t sign in. Check your details and try again."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Apple Account"].exists)
        capture(app, "Sign-in error stays in form")
        tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.staticTexts["Account ready"].waitForExistence(timeout: 10))
    }
    func testInvalidCustomServerCanBeClearedToUseDefault() {
        let app = launch("success")
        fill(app)
        tap(app.buttons["Advanced"], in: app)
        let server = app.textFields["Automatic — SideStore"]
        tap(server, in: app); server.typeText("http://example.test")
        tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.staticTexts["Enter a full HTTPS server address, or leave it blank to use SideStore."].exists)
        tap(server, in: app)
        server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "http://example.test".count))
        tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.staticTexts["Account ready"].waitForExistence(timeout: 10))
    }
    func testVerificationRetryThenSuccess() {
        let app = launch("verification")
        fill(app); tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.buttons["Send to Apple Devices"].waitForExistence(timeout: 10))
        tap(app.buttons["Send to Apple Devices"], in: app)
        let code = app.textFields["Verification code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10)); code.tap(); code.typeText("000000")
        tap(app.buttons["Continue"], in: app)
        XCTAssertTrue(app.staticTexts["That code didn’t work. Try again."].waitForExistence(timeout: 10))
        code.tap(); code.typeText("123456")
        capture(app, "Apple verification in sign-in sheet")
        tap(app.buttons["Continue"], in: app)
        XCTAssertTrue(app.staticTexts["Account ready"].waitForExistence(timeout: 10))
    }
    func testTeamSelectionSaveFailureCanRetry() {
        let app = launch("team-error")
        fill(app); tap(app.buttons["Sign In"], in: app)
        let personal = app.buttons["Example (Personal Team)"]
        XCTAssertTrue(personal.waitForExistence(timeout: 10)); tap(personal, in: app)
        XCTAssertTrue(app.staticTexts["Couldn’t save your team. Try again."].waitForExistence(timeout: 10))
        tap(personal, in: app)
        XCTAssertTrue(app.staticTexts["Account ready"].waitForExistence(timeout: 10))
    }
    func testVerificationFailureReturnsToEditableCredentialsAndCancelWorks() {
        let app = launch("verification-error")
        fill(app); tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.buttons["Send to Apple Devices"].waitForExistence(timeout: 10))
        tap(app.buttons["Send to Apple Devices"], in: app)
        let code = app.textFields["Verification code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10)); code.tap(); code.typeText("123456")
        tap(app.buttons["Continue"], in: app)
        XCTAssertTrue(app.staticTexts["Apple couldn’t finish sign-in. Try again."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["Password"].isEnabled)
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Sign-in fixture ready"].waitForExistence(timeout: 5))
    }
    func testCancelWhileWaitingForAppleVerification() {
        let app = launch("verification")
        fill(app); tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.buttons["Send to Apple Devices"].waitForExistence(timeout: 10))
        tap(app.buttons["Send to Apple Devices"], in: app)
        XCTAssertTrue(app.textFields["Verification code"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Sign-in fixture ready"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Account ready"].exists)
    }
    func testEmptyTeamsShowsRecoveryInsteadOfDismissing() {
        let app = launch("empty-teams")
        fill(app); tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.staticTexts["No signing teams were found. Finish setting up this account in Xcode, then try again."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["Password"].isEnabled)
    }
    func testLargestTextKeyboardStillAllowsSignIn() {
        let app = launch("success", largeText: true)
        fill(app)
        capture(app, "Largest text with keyboard")
        tap(app.buttons["Sign In"], in: app)
        XCTAssertTrue(app.staticTexts["Account ready"].waitForExistence(timeout: 10))
    }
}
