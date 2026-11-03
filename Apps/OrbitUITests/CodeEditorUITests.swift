import XCTest

final class CodeEditorUITests: XCTestCase {
    func testAppsShowsCachedListBeforeRefreshingOnPageLoad() {
        let app = XCUIApplication(); app.launchArguments = ["--target-build-preview", "--target-cache-delayed"]; app.launch()
        XCTAssertTrue(app.cells["OrbitTarget:cached"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.cells["OrbitTarget:fixture"].exists)
        attach("Cached apps while refreshing", app)
        XCTAssertTrue(app.cells["OrbitTarget:fixture"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.cells["OrbitTarget:cached"].exists)
    }

    func testMacUpdateHasSeparateSectionAndReconnects() {
        let app = XCUIApplication(); app.launchArguments = ["--target-build-preview"]; app.launch()
        let rebuild = app.buttons["OrbitMacRebuild"]
        XCTAssertTrue(rebuild.waitForExistence(timeout: 10)); rebuild.tap()
        XCTAssertTrue(app.cells["OrbitMacUpdate"].staticTexts["Updating Orbit Mac…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["OrbitTarget:fixture"].exists)
        XCTAssertTrue(app.staticTexts["Orbit Mac is up to date."].waitForExistence(timeout: 20))
        XCTAssertTrue(rebuild.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testMacUpdateFailureKeepsRetryAndLog() {
        let app = XCUIApplication(); app.launchArguments = ["--target-build-preview", "--target-mac-update-failure", "--target-list-empty"]; app.launch()
        let rebuild = app.buttons["OrbitMacRebuild"]
        XCTAssertTrue(rebuild.waitForExistence(timeout: 10)); rebuild.tap()
        XCTAssertTrue(app.staticTexts["Fixture Mac signing failed."].waitForExistence(timeout: 20))
        XCTAssertTrue(rebuild.isEnabled)
        app.cells["OrbitMacUpdate"].tap()
        XCTAssertTrue(app.alerts["Orbit Mac Update"].staticTexts["Fixture Mac build output\n"].waitForExistence(timeout: 3))
    }

    func testAppsListFailureCanRetryAndEmptyCatalogExplainsAdd() {
        let app = XCUIApplication()
        app.launchArguments = ["--target-build-preview", "--target-list-retry"]
        app.launch()
        XCTAssertTrue(app.staticTexts["OrbitTargetsMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 3))
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.cells["OrbitTarget:fixture"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--target-build-preview", "--target-list-empty"]
        app.launch()
        let message = app.staticTexts["OrbitTargetsMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label CONTAINS 'No apps yet'"), evaluatedWith: message)
        waitForExpectations(timeout: 5)
    }

    func testAppsBuildRequiresWiFiBeforeRequestAndCanRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--target-build-preview", "--target-no-wifi"]
        app.launch()
        let row = app.cells["OrbitTarget:fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for attempt in 0..<2 {
            if attempt == 0 { app.buttons["OrbitTargetPlay:fixture"].tap() }
            else { row.tap(); app.buttons["OrbitTargetPlay:fixture"].tap() }
            let alert = app.alerts["Wi-Fi Needed"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts["Connect this phone to Wi-Fi, then try again. Remote app installation can’t use cellular alone."].exists)
            XCTAssertFalse(app.descendants(matching: .any)["CodeBuildProgress"].exists)
            attach("Wi-Fi needed before remote build", app)
            alert.buttons["OK"].tap()
            XCTAssertTrue(app.buttons["OrbitTargetPlay:fixture"].isEnabled)
            XCTAssertFalse(app.descendants(matching: .any)["OrbitTargetProgress:fixture"].exists)
            if attempt == 0 { row.tap() }
            // Let the production catalog poll expose any mistakenly sent build RPC.
            let unexpectedRequest = expectation(for: NSPredicate { _, _ in
                (app.textViews["OrbitTargetMessage"].value as? String ?? "").contains("Build requests: 1")
            }, evaluatedWith: nil)
            unexpectedRequest.isInverted = true
            waitForExpectations(timeout: 4)
            XCTAssertTrue((app.textViews["OrbitTargetMessage"].value as? String ?? "").contains("Build requests: 0"))
            app.buttons["Close app details"].tap()
        }
        // The next probe models joining Wi-Fi; the same play button now starts work.
        app.buttons["OrbitTargetPlay:fixture"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["CodeBuildProgress"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Compile Feature.swift"].exists)
    }

    func testAppsBuildShowsLiveProgressConsoleAndCompletion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--target-build-preview"]
        app.launch()
        let row = app.cells["OrbitTarget:fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.buttons["OrbitTargetPlay:fixture"].tap()
        let progress = app.descendants(matching: .any)["CodeBuildProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        let first = progress.value as? String
        XCTAssertTrue(app.staticTexts["Compile Feature.swift"].exists)
        app.buttons["Show Console"].tap()
        XCTAssertTrue(app.textViews["CodeBuildConsole"].value as? String == "Compile Feature.swift\nFixture build output\n")
        app.buttons["Hide Console"].tap()
        expectation(for: NSPredicate { _, _ in progress.value as? String != first }, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
        attach("Apps live build progress", app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["OrbitTargetProgress:fixture"].exists)
        XCTAssertFalse(row.label.lowercased().contains("estimated"))
        XCTAssertFalse((app.descendants(matching: .any)["OrbitTargetProgress:fixture"].value as? String ?? "").contains("%"))
        row.tap()
        expectation(for: NSPredicate { _, _ in (app.textViews["OrbitTargetMessage"].value as? String ?? "").contains("Installed on your phone") }, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
        attach("Apps confirmed completion", app)
    }
    func testAppsBuildFailureIsVisibleAfterDismissingProgress() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--target-build-preview", "--target-build-failure", "--target-build-disconnect"]
        app.launch()
        let row = app.cells["OrbitTarget:fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        app.buttons["OrbitTargetPlay:fixture"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["CodeBuildProgress"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["CodeBuildStatus"].waitForExistence(timeout: 3))
        expectation(for: NSPredicate { _, _ in app.staticTexts["CodeBuildStatus"].label.contains("Reconnecting") }, evaluatedWith: nil)
        waitForExpectations(timeout: 7)
        app.buttons["Done"].tap()
        app.buttons["Close app details"].tap()
        expectation(for: NSPredicate { _, _ in row.buttons["OrbitTargetIssue:fixture"].exists }, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
        let size = row.frame.size
        row.buttons["OrbitTargetIssue:fixture"].tap()
        XCTAssertTrue((app.textViews["OrbitTargetMessage"].value as? String ?? "").contains("Fixture compilation failed"))
        app.buttons["View Build Log"].tap()
        XCTAssertTrue(app.textViews["CodeBuildConsole"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["CodeBuildConsole"].value as? String ?? "").contains("Fixture build output"))
        app.buttons["Done"].tap()
        app.buttons["Close app details"].tap()
        XCTAssertEqual(row.frame.size, size)
        attach("Apps failure after reconnect", app)
    }

    func testTargetListDisplaysIconsAndMissingImageFallbacks() {
        let app = XCUIApplication()
        app.launchArguments = ["--target-icons-preview"]
        app.launch()
        XCTAssertTrue(app.cells["OrbitTarget:preview"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.cells["OrbitTarget:missing"].exists)
        XCTAssertTrue(app.cells["OrbitTarget:invalid"].exists)
        let first = app.cells["OrbitTarget:preview"]
        let second = app.cells["OrbitTarget:missing"]
        let third = app.cells["OrbitTarget:invalid"]
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 2)
        XCTAssertGreaterThan(second.frame.minX, first.frame.maxX)
        XCTAssertGreaterThanOrEqual(first.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(second.frame.maxX, app.frame.maxX)
        XCTAssertTrue(first.isHittable)
        XCTAssertTrue(second.isHittable)
        XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 2)
        XCTAssertEqual(first.frame.width, 160, accuracy: 1)
        XCTAssertEqual(first.frame.height, 220, accuracy: 1)
        XCTAssertEqual(second.frame.height, first.frame.height, accuracy: 1)
        if app.frame.width < 536 {
            XCTAssertGreaterThan(third.frame.minY, first.frame.maxY)
            XCTAssertEqual(first.frame.minX, third.frame.minX, accuracy: 2)
        } else {
            XCTAssertEqual(third.frame.minY, first.frame.minY, accuracy: 2)
            XCTAssertGreaterThan(third.frame.minX, second.frame.maxX)
        }
        let age = first.descendants(matching: .any)["OrbitTargetLastBuilt:preview"]
        XCTAssertEqual(age.value as? String, "14hr")
        XCTAssertEqual(second.descendants(matching: .any)["OrbitTargetLastBuilt:missing"].value as? String, "2d")
        XCTAssertEqual(third.descendants(matching: .any)["OrbitTargetLastBuilt:invalid"].label, "Not built yet")
        let play = first.buttons["OrbitTargetPlay:preview"]
        let icon = first.images["OrbitTargetIcon"]
        XCTAssertEqual(icon.frame.width, 60, accuracy: 1)
        XCTAssertLessThan(icon.frame.maxY, play.frame.minY)
        XCTAssertLessThan(age.frame.maxX, play.frame.minX)
        XCTAssertEqual(age.frame.midY, play.frame.midY, accuracy: 2)
        attach("Two-column app tiles with build ages and icon fallbacks", app)
    }
    func testTargetTilesKeepControlsWithLargestText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--target-icons-preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let grid = app.collectionViews["OrbitTargets"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        let first = app.cells["OrbitTarget:preview"]
        let play = app.buttons["OrbitTargetPlay:preview"]
        for _ in 0..<8 {
            if play.exists && play.isHittable { break }
            grid.swipeUp()
        }
        XCTAssertTrue(play.isHittable)
        let age = first.descendants(matching: .any)["OrbitTargetLastBuilt:preview"]
        XCTAssertLessThan(age.frame.maxX, play.frame.minX)
        XCTAssertGreaterThanOrEqual(age.frame.minX, first.frame.minX)
        XCTAssertLessThanOrEqual(play.frame.maxX, first.frame.maxX)
        XCTAssertEqual(play.frame.width, 44, accuracy: 1)
        XCTAssertEqual(age.value as? String, "14hr")
        attach("App tile controls at largest text size", app)
    }

    func testBuildRequestFailureUsesIssueIconWithoutResizing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--target-build-preview", "--target-build-request-failure"]
        app.launch()
        let row = app.cells["OrbitTarget:fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let original = row.frame.size
        row.buttons["OrbitTargetPlay:fixture"].tap()
        let issue = row.buttons["OrbitTargetIssue:fixture"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertEqual(row.frame.size, original)
        XCTAssertFalse(app.alerts["Apps"].exists)
        issue.tap()
        XCTAssertTrue((app.textViews["OrbitTargetMessage"].value as? String ?? "").contains("Fixture build request failed"))
        XCTAssertTrue(app.buttons["OrbitTargetPlay:fixture"].isEnabled)
        app.buttons["Close app details"].tap()
        XCTAssertEqual(row.frame.size, original)
    }

    func testFixedTargetCardExpandsWithBoundedLongErrorAndSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--target-build-preview", "--target-long-error"]
        app.launch()
        let row = app.cells["OrbitTarget:fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let original = row.frame
        XCTAssertEqual(original.width, 160, accuracy: 1)
        XCTAssertEqual(original.height, 220, accuracy: 1)
        XCTAssertFalse(row.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Diagnostic'")).firstMatch.exists)
        row.buttons["OrbitTargetIssue:fixture"].tap()
        let panel = app.otherElements["OrbitTargetDetail"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(panel.frame.height, original.height)
        XCTAssertGreaterThan(panel.frame.minX, app.frame.minX)
        XCTAssertLessThan(panel.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThan(panel.frame.minY, app.frame.minY)
        XCTAssertLessThan(panel.frame.maxY, app.frame.maxY)
        XCTAssertEqual(panel.images["OrbitTargetIcon"].frame.width, 60, accuracy: 1)
        let message = app.textViews["OrbitTargetMessage"]
        XCTAssertTrue((message.value as? String ?? "").contains("Diagnostic 80"))
        let textFrame = message.frame
        message.swipeUp()
        XCTAssertEqual(message.frame, textFrame)
        for label in ["Refresh settings", "Cache build", "Remove App Target", "View Build Log", "Close app details"] {
            XCTAssertTrue(app.buttons[label].exists)
            XCTAssertGreaterThanOrEqual(app.buttons[label].frame.minY, panel.frame.minY)
            XCTAssertLessThanOrEqual(app.buttons[label].frame.maxY, panel.frame.maxY)
        }
        app.buttons["Refresh settings"].tap()
        app.buttons["Every six days"].tap()
        expectation(for: NSPredicate(format: "value CONTAINS '144'"), evaluatedWith: app.buttons["Refresh settings"])
        waitForExpectations(timeout: 5)
        attach("Expanded card with long error and fixed controls", app)
        app.buttons["Close app details"].tap()
        XCTAssertEqual(row.frame, original)
        row.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.buttons["Remove App Target"].tap()
        app.alerts["Remove this app?"].buttons["Cancel"].tap()
        XCTAssertTrue(panel.exists)
        app.buttons["Close app details"].tap()
        XCTAssertEqual(row.frame, original)
    }

    func testExpandedTargetKeepsControlsInLandscapeWithLargestText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--target-build-preview", "--target-long-error", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        let row = app.cells["OrbitTarget:fixture"]
        let grid = app.collectionViews["OrbitTargets"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            if row.exists && row.isHittable { break }
            grid.swipeUp()
        }
        XCTAssertTrue(row.isHittable)
        row.buttons["OrbitTargetIssue:fixture"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let panel = app.otherElements["OrbitTargetDetail"]
        let message = app.textViews["OrbitTargetMessage"]
        XCTAssertGreaterThan(message.frame.height, 44)
        XCTAssertEqual(panel.images["OrbitTargetIcon"].frame.width, 60, accuracy: 1)
        for label in ["Refresh settings", "Cache build", "Remove App Target", "View Build Log", "Close app details"] {
            let control = app.buttons[label]
            XCTAssertTrue(control.exists)
            XCTAssertGreaterThanOrEqual(control.frame.minX, panel.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, panel.frame.maxX)
            XCTAssertGreaterThanOrEqual(control.frame.minY, panel.frame.minY)
            XCTAssertLessThanOrEqual(control.frame.maxY, panel.frame.maxY)
        }
        XCTAssertLessThanOrEqual(message.frame.maxY, app.buttons["Refresh settings"].frame.minY)
        Thread.sleep(forTimeInterval: 1)
        attach("Landscape expanded card at largest text size", app)
        app.buttons["Close app details"].tap()
        XCTAssertEqual(row.frame.width, 160, accuracy: 1)
        XCTAssertEqual(row.frame.height, 220, accuracy: 1)
    }

    func testIPadRotationAndTargetMenu() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout check") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--target-icons-preview"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        let row = app.cells["OrbitTarget:preview"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        attach("iPad apps portrait", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(row.frame.width, 160, accuracy: 1)
        XCTAssertEqual(row.frame.height, 220, accuracy: 1)
        row.tap()
        let panel = app.otherElements["OrbitTargetDetail"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(panel.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(panel.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, app.frame.minY)
        XCTAssertLessThanOrEqual(panel.frame.maxY, app.frame.maxY)
        // The screenshot surface settles after UIKit has updated its frames.
        Thread.sleep(forTimeInterval: 1)
        attach("iPad target menu landscape", app)
        app.terminate()
    }

    func testIPadSidebarCanOpenRefresh() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad sidebar check") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--reset-connection"]
        app.launch()
        let toggle = app.buttons["Toggle sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        toggle.tap()
        attach("iPad sidebar destinations", app)
        let refresh = app.descendants(matching: .any).matching(identifier: "Refresh").firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        XCTAssertTrue(app.buttons["Refresh All"].waitForExistence(timeout: 5))
        attach("iPad sidebar refresh", app)
    }

    func testStandaloneLaunchShowsMacSetupAndApps() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-connection"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Connect a Mac"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        app.tabBars.buttons["Apps"].tap()
        if app.alerts["Orbit"].waitForExistence(timeout: 3) { app.alerts["Orbit"].buttons["OK"].tap() }
        XCTAssertTrue(app.navigationBars["Apps"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Mac"].tap()
        XCTAssertTrue(app.staticTexts["Connect a Mac"].waitForExistence(timeout: 5))
    }

    func testRotationEditingExplicitSaveAndDraftRecovery() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-preview"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let editor = app.scrollViews.children(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        app.typeText("// phone edit\n")
        let save = app.buttons["Save to Mac"]
        XCTAssertTrue(save.isEnabled)
        attach("Portrait · software keyboard", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in editor.frame.width > editor.frame.height }, evaluatedWith: editor)
        waitForExpectations(timeout: 5)
        // UIKit and the simulator screenshot surface finish rotating separately.
        Thread.sleep(forTimeInterval: 1)
        app.typeText("// landscape edit\n")
        attach("Landscape · software keyboard", app)
        save.tap()
        let saved = NSPredicate(format: "enabled == false")
        expectation(for: saved, evaluatedWith: save)
        waitForExpectations(timeout: 5)
        app.typeText("// unsaved recovery\n")
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launchArguments = ["--editor-preview"]
        app.launch()
        let restored = app.scrollViews.children(matching: .textView).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue((restored.value as? String ?? "").contains("unsaved recovery"), "Restored value: \(String(describing: restored.value))")
        XCUIDevice.shared.orientation = .portrait
    }
    func testHardwareSaveShortcutOnIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("XCTest modifier-key injection requires iPadOS.") }
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-preview"]; app.launch()
        let editor = app.scrollViews.children(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15)); editor.tap(); app.typeText("// hardware edit\n")
        app.typeKey("s", modifierFlags: .command)
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: app.buttons["Save to Mac"])
        waitForExpectations(timeout: 5)
    }
    func testProjectSelectionBrowsingAndRestoration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        let folder = app.cells["CodeFile:/Preview/Sources"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Project Settings"].exists)
        attach("Project files", app)
        app.terminate()
        app.launchArguments = ["--editor-preview", "--workspace-preview"]
        app.launch()
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); folder.tap()
        app.cells["CodeFile:/Preview/Sources/Detail.swift"].tap()
        let editor = app.scrollViews.children(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); app.typeText("// project draft\n")
        XCUIDevice.shared.press(.home); app.terminate(); app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String ?? "").contains("project draft"))
        app.buttons["Editor Actions"].tap(); app.buttons["Close File"].tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        XCTAssertFalse(editor.exists, "Closing the last file must leave the project browser on relaunch")
    }

    func testSwitchProjectsAndChooseSchemeWithoutLosingBrowser() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.buttons["Browser Actions"].tap(); app.buttons["Project Settings"].tap()
        XCTAssertTrue(app.navigationBars["Project Settings"].waitForExistence(timeout: 5))
        app.navigationBars["Project Settings"].buttons["Save"].tap()
        XCTAssertTrue(app.cells.staticTexts["Sample"].waitForExistence(timeout: 10))
        app.cells.staticTexts["Sample"].tap()
        XCTAssertTrue(app.cells["CodeFile:/Preview/Welcome.swift"].waitForExistence(timeout: 5))
        app.buttons["Browser Actions"].tap(); app.buttons["Choose Build Scheme…"].tap()
        XCTAssertTrue(app.cells.staticTexts["SampleTests"].waitForExistence(timeout: 5))
        app.cells.staticTexts["SampleTests"].tap()
        app.cells["CodeFile:/Preview/Sample.xcodeproj"].tap()
        app.buttons["Browser Actions"].tap(); app.buttons["Project Settings"].tap()
        XCTAssertEqual(app.textFields["CodeSettings:Scheme"].value as? String, "SampleTests", "Reopening the current project must preserve its scheme")
        app.navigationBars["Project Settings"].buttons["Cancel"].tap()
        app.cells["CodeFile:/Preview/Welcome.swift"].tap()
        XCTAssertTrue(app.scrollViews.children(matching: .textView).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Project Files"].tap()
        app.buttons["Browser Actions"].tap(); app.buttons["Browse Mac Files"].tap()
        app.cells["CodeFile:/Other/Other.xcworkspace"].tap()
        XCTAssertTrue(app.cells["CodeFile:/Other/Other.swift"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--editor-preview", "--workspace-preview"]; app.launch()
        XCTAssertTrue(app.cells["CodeFile:/Other/Other.swift"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.scrollViews.children(matching: .textView).firstMatch.exists)
    }

    func testBrowserFailureShowsRecoveryAndRetainsProject() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        XCTAssertTrue(app.cells["CodeFile:/Preview/Sources"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--editor-preview", "--workspace-preview", "--browser-failure"]; app.launch()
        XCTAssertTrue(app.staticTexts["Couldn’t Load Files"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Retry"].exists)
        app.terminate(); app.launchArguments = ["--editor-preview", "--workspace-preview"]; app.launch()
        XCTAssertTrue(app.cells["CodeFile:/Preview/Sources"].waitForExistence(timeout: 10))
    }

    func testSaveConflictKeepsDraftUntilExplicitResolution() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-preview", "--save-conflict"]
        app.launch()
        let editor = app.scrollViews.children(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap(); app.typeText("// keep my draft\n")
        app.buttons["Save to Mac"].tap()
        let conflict = app.alerts["This file changed on your Mac"]
        XCTAssertTrue(conflict.waitForExistence(timeout: 5))
        conflict.buttons["Keep Editing"].tap()
        XCTAssertTrue((editor.value as? String ?? "").contains("keep my draft"))
        app.buttons["Save to Mac"].tap()
        XCTAssertTrue(conflict.waitForExistence(timeout: 5))
        conflict.buttons["Use iPhone Version"].tap()
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: app.buttons["Save to Mac"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue((editor.value as? String ?? "").contains("keep my draft"))
    }

    func testBuildRowHistoryAndOvernightTogglePersistOffline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let row = app.cells["CodeBuildApp:Sample"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let toggle = app.switches["CodeNightly:Sample"]
        let run = app.buttons["CodeRun:Sample"]
        let options = app.buttons["CodeBuildOptions:Sample"]
        let icon = row.images["CodeAppIcon:Sample"]
        XCTAssertTrue(icon.exists)
        XCTAssertLessThan(icon.frame.maxX, row.staticTexts["Sample"].frame.minX)
        XCTAssertFalse(toggle.frame.intersects(run.frame))
        XCTAssertFalse(toggle.frame.intersects(options.frame))
        for control in [toggle, run, options] {
            XCTAssertTrue(row.frame.contains(control.frame), "Build controls must fit inside their row")
        }
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap(); XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["CodeRun:Sample"].tap()
        XCTAssertTrue(app.staticTexts["Build Completed"].waitForExistence(timeout: 20))
        app.buttons["Done"].tap()
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "abc12345")).firstMatch.waitForExistence(timeout: 5))
        let copy = row.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertFalse(copy.contains("Preview iPhone")); XCTAssertFalse(copy.contains("main"))
        attach("Build history and overnight switch", app)
        app.terminate()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--build-offline"]
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "abc12345")).firstMatch.exists)
    }

    func testLaunchAfterInstallIsPerSchemeAndPersistsAcrossDiscoveryAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview", "--expect-build-launch"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let run = app.buttons["CodeRun:Sample"]
        XCTAssertTrue(run.waitForExistence(timeout: 15))
        XCTAssertEqual(run.label, "Build and Install Sample")
        app.buttons["CodeBuildOptions:Sample"].tap()
        let launch = app.buttons["Launch After Install"]
        XCTAssertTrue(launch.waitForExistence(timeout: 5)); launch.tap()
        XCTAssertEqual(run.label, "Build and Run Sample")
        let alias = app.buttons["CodeRun:SampleAlias"]
        XCTAssertTrue(alias.waitForExistence(timeout: 15))
        XCTAssertEqual(alias.label, "Build and Install SampleAlias")
        app.terminate()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--expect-build-launch"]
        app.launch()
        XCTAssertTrue(run.waitForExistence(timeout: 15))
        XCTAssertEqual(run.label, "Build and Run Sample")
        XCTAssertEqual(alias.label, "Build and Install SampleAlias")
        run.tap()
        // The fixture rejects a request that doesn't match the selected launch mode.
        XCTAssertTrue(app.staticTexts["Build Completed"].waitForExistence(timeout: 20))
        app.buttons["Done"].tap()
        app.buttons["CodeBuildOptions:Sample"].tap()
        XCTAssertTrue(launch.waitForExistence(timeout: 5)); launch.tap()
        XCTAssertEqual(run.label, "Build and Install Sample")
        attach("Per-scheme launch setting", app)
    }

    func testBuildRowFitsAtAccessibilityTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let row = app.cells["CodeBuildApp:Sample"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let toggle = app.switches["CodeNightly:Sample"]
        let run = app.buttons["CodeRun:Sample"]
        let options = app.buttons["CodeBuildOptions:Sample"]
        XCTAssertLessThan(toggle.frame.maxY, run.frame.minY, "Large text should stack the control groups")
        for control in [toggle, run, options] { XCTAssertTrue(row.frame.contains(control.frame)) }
        toggle.tap(); XCTAssertEqual(toggle.value as? String, "1")
        attach("Build row at accessibility text size", app)
    }

    func testBuildsCacheOneTapMainBuildAndLastTabRestoration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let row = app.cells["CodeBuildApp:Sample"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(app.cells["CodeBuildApp:SampleCompanion"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["CodeBuildApp:SampleAlias"].exists)
        XCTAssertFalse(app.cells["CodeBuildApp:SampleTests"].exists)
        attach("Cached app builds", app)
        app.buttons["CodeBuildOptions:Sample"].tap()
        XCTAssertTrue(app.buttons["Branch: main"].waitForExistence(timeout: 5))
        app.buttons["Branch: main"].tap()
        XCTAssertTrue(app.cells.staticTexts["feature/preview"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["CodeRun:Sample"].tap()
        XCTAssertTrue(app.staticTexts["CodeBuildStatus"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["CodeBuildStatus"].label.contains("You can leave Orbit"))
        XCTAssertFalse(app.textViews["CodeBuildConsole"].exists)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 7)
        app.activate()
        XCTAssertTrue(app.staticTexts["Build Completed"].waitForExistence(timeout: 10))
        app.buttons["Show Console"].tap()
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "Preview build from main on Preview iPhone")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        app.terminate(); app.launchArguments = ["--editor-preview", "--workspace-preview", "--build-offline"]; app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Builds"].isSelected)
        app.tabBars.buttons["Project"].tap()
        XCTAssertTrue(app.cells["CodeFile:/Preview/Sources"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.cells["CodeFile:/Preview/Sources"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Project"].isSelected)
    }

    func testBuildStartupSurvivesImmediateBackgroundAndShowsProgress() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview", "--build-start-delay"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let run = app.buttons["CodeRun:Sample"]
        XCTAssertTrue(run.waitForExistence(timeout: 15)); run.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Starting… · Keep Orbit open")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(run.isEnabled, "Play must stay disabled while the Mac accepts the build")
        attach("Remote build startup", app)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 13)
        app.activate()
        XCTAssertTrue(app.staticTexts["Build Completed"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["CodeBuildProgress"].exists)
        XCTAssertTrue(app.staticTexts["100%"].exists)
        attach("Background build completed", app)
    }

    func testBuildWithoutStageMetadataWaitsForRealUpdates() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview", "--build-no-progress"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let run = app.buttons["CodeRun:Sample"]
        XCTAssertTrue(run.waitForExistence(timeout: 15)); run.tap()
        let progress = app.descendants(matching: .any)["CodeBuildProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertEqual(progress.value as? String, "Waiting for build updates…")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(progress.value as? String, "Waiting for build updates…")
        XCTAssertFalse(app.staticTexts["Build Completed"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "estimated")).firstMatch.exists)
        attach("Waiting without a fabricated percentage", app)
        XCTAssertTrue(app.staticTexts["Build Completed"].waitForExistence(timeout: 30))
        XCTAssertEqual(progress.value as? String, "100%")
    }

    func testActualBuildTaskDetailsAndProgressUpdateTogether() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview", "--build-events"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let run = app.buttons["CodeRun:Sample"]
        XCTAssertTrue(run.waitForExistence(timeout: 15)); run.tap()
        let work = app.staticTexts["CodeBuildWork"]
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        XCTAssertTrue(work.label.contains("build tasks completed"))
        XCTAssertTrue(app.staticTexts["Compile Feature.swift (arm64)"].exists)
        let initial = work.label
        let progress = app.descendants(matching: .any)["CodeBuildProgress"]
        let initialProgress = progress.value as? String
        XCTAssertTrue(initialProgress?.contains("build tasks completed") == true)
        XCTAssertFalse(initialProgress?.contains("%") == true)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "estimated")).firstMatch.exists)
        expectation(for: NSPredicate { _, _ in work.label != initial && progress.value as? String != initialProgress }, evaluatedWith: work)
        waitForExpectations(timeout: 6)
        attach("Real task count and current operation", app)
        XCTAssertTrue(app.staticTexts["Build Completed"].waitForExistence(timeout: 25))
    }
    func testSelfUpdateHandoffRestoresInstallationAfterProcessReplacement() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview", "--build-self-update"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let run = app.buttons["CodeRun:Sample"]
        XCTAssertTrue(run.waitForExistence(timeout: 15)); run.tap()
        XCTAssertTrue(app.staticTexts["Build Complete — Updating Orbit"].waitForExistence(timeout: 15))
        let detail = app.staticTexts["CodeBuildStatus"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Installing the update. Orbit may close."), evaluatedWith: detail)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts["Build Completed"].exists, "Installation has not completed yet")
        attach("Self-update handed off", app)
        app.terminate()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--build-self-update"]
        app.launch()
        let options = app.buttons["CodeBuildOptions:Sample"]
        XCTAssertTrue(options.waitForExistence(timeout: 15)); options.tap()
        app.buttons["Build Log"].tap()
        let hideConsole = app.buttons["Hide Console"]
        XCTAssertTrue(hideConsole.waitForExistence(timeout: 5)); hideConsole.tap()
        XCTAssertTrue(app.staticTexts["Build Completed"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Build Failed"].exists)
        app.buttons["Show Console"].tap()
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "only after the activity handoff was acknowledged")).firstMatch.exists)
    }

    func testBuildOptionsStayOpenWhileDiscoveryContinuesPastFailedAndLibrarySchemes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview", "--build-discovery-delay"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let options = app.buttons["CodeBuildOptions:Sample"]
        XCTAssertTrue(options.waitForExistence(timeout: 15)); options.tap()
        let branch = app.buttons["Branch: main"]
        XCTAssertTrue(branch.waitForExistence(timeout: 5))
        // Discovery returns an empty scheme, an error and two new app rows,
        // while several foreground job-poll ticks also pass.
        Thread.sleep(forTimeInterval: 12)
        XCTAssertTrue(branch.exists, "Discovery and polling must preserve an open row menu")
        branch.tap()
        XCTAssertTrue(app.cells.staticTexts["feature/preview"].waitForExistence(timeout: 5))
        app.cells.staticTexts["feature/preview"].tap()
        XCTAssertTrue(app.cells["CodeBuildApp:SampleCompanion"].waitForExistence(timeout: 10), "A failed scheme must not hide later apps")
        XCTAssertFalse(app.cells["CodeBuildApp:SampleLibrary"].exists)
        options.tap()
        XCTAssertTrue(app.buttons["Branch: feature/preview"].waitForExistence(timeout: 5), "Preserved buttons must read the latest row settings")
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
