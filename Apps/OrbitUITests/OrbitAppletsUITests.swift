import XCTest

final class OrbitAppletsUITests: XCTestCase {
    func testImportConsentLaunchActionAndPersistence() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["Applets"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Applets"].tap()
        app.navigationBars["Applets"].buttons["Add"].tap(); app.buttons["Paste JavaScript"].tap()
        let editor = app.textViews.firstMatch; XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("/* orbit-applet\n{\"id\":\"applet-ui-test\",\"name\":\"Test Applet\",\"domains\":[]}\n*/\nmodule.exports={update(ctx){ctx.storage.set('n',0)},action(ctx,e){ctx.storage.set('n',ctx.storage.get('n',0)+1)},render(ctx){return {type:'vstack',children:[{type:'text',text:'Count '+ctx.storage.get('n',0)},{type:'button',text:'Add one',action:'add'}]}}};")
        app.navigationBars["JavaScript"].buttons["Review"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Count 0"].exists)
        if app.alerts.buttons["Add Applet"].exists { app.alerts.buttons["Add Applet"].tap() } else { app.alerts.buttons["Update Applet"].tap() }
        XCTAssertTrue(app.staticTexts["Count 0"].waitForExistence(timeout: 10))
        app.buttons["Add one"].tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "JavaScript Applet"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
