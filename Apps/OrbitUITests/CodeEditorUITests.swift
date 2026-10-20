import XCTest

final class CodeEditorUITests: XCTestCase {
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
        XCTAssertTrue(row.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "abc12345")).firstMatch.waitForExistence(timeout: 5))
        let copy = row.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertFalse(copy.contains("Preview iPhone")); XCTAssertFalse(copy.contains("main"))
        attach("Build history and overnight switch", app)
        app.terminate()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--build-offline"]
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(row.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "abc12345")).firstMatch.exists)
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
        XCTAssertTrue(app.descendants(matching: .any)["CodeRowProgress:Sample"].exists, app.debugDescription)
        attach("Remote build startup", app)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 13)
        app.activate()
        XCTAssertTrue(app.staticTexts["Build Completed"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["CodeBuildProgress"].exists)
        XCTAssertTrue(app.staticTexts["100%"].exists)
        attach("Background build completed", app)
    }

    func testBuildWithoutStageMetadataAdvancesBeforeCompletion() {
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
        func percentage() -> Int { Int((progress.value as? String ?? "").split(separator: " ").first ?? "0") ?? 0 }
        let first = percentage()
        expectation(for: NSPredicate { _, _ in percentage() > first && percentage() < 100 }, evaluatedWith: progress)
        waitForExpectations(timeout: 6)
        let second = percentage()
        expectation(for: NSPredicate { _, _ in percentage() > second && percentage() < 100 }, evaluatedWith: progress)
        waitForExpectations(timeout: 6)
        XCTAssertFalse(app.staticTexts["Build Completed"].exists)
        attach("Incremental estimate without Mac stage metadata", app)
        XCTAssertTrue(app.staticTexts["Build Completed"].waitForExistence(timeout: 30))
        XCTAssertEqual(percentage(), 100)
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
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Your Mac is installing the update"), evaluatedWith: detail)
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
