import XCTest

final class OrbitAppletsUITests: XCTestCase {
    func testPollingConsentParsesAndPersistsWithoutRepeatingBeforeDue() throws {
        let app = XCUIApplication(), springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = ["--reset-connection"]; app.launch()
        app.tabBars.buttons["Applets"].tap()
        app.navigationBars["Applets"].buttons["Add"].tap(); app.buttons["Paste JavaScript"].tap()
        let editor = app.textViews.firstMatch; XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        let id = "poll-" + UUID().uuidString.lowercased()
        editor.typeText("/* orbit-applet\n{\"id\":\"\(id)\",\"name\":\"Polling Fixture\",\"domains\":[],\"pollHours\":6,\"notifications\":true}\n*/\nmodule.exports={poll(ctx){const data=JSON.parse('{\"value\":\"Parsed result\"}');ctx.storage.set('result',data.value);ctx.storage.set('n',ctx.storage.get('n',0)+1);ctx.notify({id:'first',title:'Polling test',body:data.value})},render(ctx){return {type:'text',text:ctx.storage.get('result','Not run')+' · Checks '+ctx.storage.get('n',0)}}};")
        app.navigationBars["JavaScript"].buttons["Review"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'every 6 hours' AND label CONTAINS 'Can send notifications'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Parsed result · Checks 1"].exists)
        alert.buttons["Add Applet"].tap()
        if springboard.buttons["Allow"].waitForExistence(timeout: 3) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.staticTexts["Parsed result · Checks 1"].waitForExistence(timeout: 15))
        app.navigationBars["Polling Fixture"].buttons["Reload"].tap()
        XCTAssertTrue(app.staticTexts["Parsed result · Checks 1"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.tabBars.buttons["Applets"].tap()
        app.cells.containing(.staticText, identifier: "Polling Fixture").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Parsed result · Checks 1"].waitForExistence(timeout: 10))
    }
    func testImportConsentLaunchActionAndPersistence() throws {
        let app = XCUIApplication(); app.launchArguments = ["--reset-connection"]; app.launch()
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
    func testReceivedFileWaitsForReviewAndSurvivesRelaunch() throws {
        let app = XCUIApplication()
        let id = "inbox-" + UUID().uuidString.lowercased()
        app.launchArguments = ["--reset-connection", "--script-inbox-fixture", id]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Applets"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Applets"].tap()
        XCTAssertTrue(app.staticTexts["Received Applet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Approved received applet"].exists)
        app.terminate(); app.launchArguments = ["--reset-connection"]; app.launch()
        app.tabBars.buttons["Applets"].tap()
        let pending = app.cells.containing(.staticText, identifier: "Review to add").firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5)); pending.tap()
        XCTAssertTrue(app.alerts.buttons["Add Applet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Approved received applet"].exists)
        app.alerts.buttons["Add Applet"].tap()
        XCTAssertTrue(app.staticTexts["Approved received applet"].waitForExistence(timeout: 10))
    }
    func testWidgetPastedInAppletsRoutesToWidgetsBeforeConsent() throws {
        let app = XCUIApplication(); app.launchArguments = ["--reset-connection"]; app.launch()
        app.tabBars.buttons["Applets"].tap()
        app.navigationBars["Applets"].buttons["Add"].tap(); app.buttons["Paste JavaScript"].tap()
        let editor = app.textViews.firstMatch; XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("/* orbit-widget\n{\"id\":\"inferred-ui\",\"name\":\"Inferred Widget\",\"domains\":[],\"refreshMinutes\":30}\n*/\nmodule.exports.render=()=>({type:'text',text:'Inferred preview'});")
        app.navigationBars["JavaScript"].buttons["Review"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Widgets"].isSelected)
        XCTAssertFalse(app.staticTexts["Inferred preview"].exists)
        app.alerts.buttons["Cancel"].tap()
    }
    func testStandaloneConsentActionAndRelaunch() throws {
        guard let bundleID = ProcessInfo.processInfo.environment["ORBIT_TEST_STANDALONE_APPLET"] else { throw XCTSkip("Install an exported blank host and set ORBIT_TEST_STANDALONE_APPLET.") }
        let app = XCUIApplication(bundleIdentifier: bundleID); app.launch()
        let open = app.buttons["Open Applet"]
        if open.waitForExistence(timeout: 5) { open.tap() }
        XCTAssertTrue(app.buttons["Tap me"].waitForExistence(timeout: 10))
        app.buttons["Tap me"].tap()
        let count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Taps: '")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        let label = count.label
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Open Applet"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Standalone JavaScript Applet"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
