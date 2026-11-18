import XCTest

final class OrbitWidgetsUITests: XCTestCase {
    func testImportConsentAndNativeJavaScriptPreviewWithoutMac() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Widgets"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Widgets"].tap()
        app.navigationBars["Widgets"].buttons["Add"].tap()
        app.buttons["Paste JavaScript"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("/* orbit-widget\n{\"id\":\"widget-ui-test\",\"name\":\"UI Test Widget\",\"domains\":[],\"refreshMinutes\":30}\n*/\nmodule.exports.render=()=>({type:'text',text:'Hello from JavaScript',size:20});")
        app.navigationBars["JavaScript"].buttons["Review"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["No network access.\n\nThis JavaScript can save its own data on your phone. Only add code you trust."].exists)
        let addButton = app.alerts.buttons["Add Widget"]
        if addButton.exists { addButton.tap() } else { app.alerts.buttons["Update Widget"].tap() }
        XCTAssertTrue(app.staticTexts["Hello from JavaScript"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.navigationBars["UI Test Widget"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "JavaScript Widget Preview"; attachment.lifetime = .keepAlways; add(attachment)

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.segmentedControls.buttons["Large"].tap()
        let help = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Add an Orbit widget")).firstMatch
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        scroll.swipeUp()
        XCTAssertTrue(help.isHittable)
    }
}
