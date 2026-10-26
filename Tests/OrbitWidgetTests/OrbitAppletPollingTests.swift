import XCTest
@testable import OrbitWidgets

final class OrbitAppletPollingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func source(_ body: String, metadata: String = ",\"pollHours\":2,\"notifications\":true") -> String {
        "/* orbit-applet\n{\"id\":\"monitor\",\"name\":\"Monitor\",\"domains\":[]\(metadata)}\n*/\n" + body
    }
    private func fixture(_ source: String) throws -> (OrbitWidgetStore, OrbitWidgetScript, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OrbitWidgetStore(directory: root, applets: true)
        try store.install(source)
        return (store, try OrbitAppletDefinition.widgetScript(source), root)
    }
    private let hook = #"""
    module.exports.poll = ctx => {
      const result = JSON.parse('{"version":"v2"}');
      ctx.storage.set('version', result.version);
      ctx.storage.set('checks', ctx.storage.get('checks',0)+1);
      ctx.notify({id:result.version,title:'New version',body:result.version});
    };
    module.exports.render = ctx => ({type:'text',text:ctx.storage.get('version','Waiting')});
    """#
    func testInertMetadataValidationAndLegacyCompatibility() throws {
        XCTAssertNil(try OrbitAppletDefinition.parse(source("throw 1", metadata: "")).pollHours)
        XCTAssertEqual(try OrbitAppletDefinition.parse(source("throw 1")).pollHours, 2)
        for metadata in [",\"pollHours\":0", ",\"pollHours\":-1", ",\"pollHours\":8761", ",\"pollHours\":\"2\"", ",\"notifications\":true"] {
            XCTAssertThrowsError(try OrbitAppletDefinition.parse(source("", metadata: metadata)))
        }
        XCTAssertEqual(try OrbitAppletDefinition.parse(source("", metadata: ",\"pollHours\":0.25")).pollHours, 0.25)
    }
    func testDueChecksParsePersistDeduplicateAndSurviveRestart() async throws {
        let (store, script, root) = try fixture(source(hook))
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = OrbitAppletRunner(), delivered = Notices()
        try await runner.check(script: script, store: store, now: now) { await delivered.add($0) }
        XCTAssertEqual(try store.storage(script.id)["version"], "\"v2\"")
        XCTAssertEqual(try store.pollingState(script.id)?.lastSuccess, now)
        let next = try await runner.nextCheck(store: store, now: now)
        XCTAssertEqual(next, now.addingTimeInterval(7200))
        let restarted = OrbitWidgetStore(directory: root, applets: true)
        try await OrbitAppletRunner().check(script: script, store: restarted, now: now.addingTimeInterval(7100)) { await delivered.add($0) }
        XCTAssertEqual(try restarted.storage(script.id)["checks"], "1")
        try await runner.check(script: script, store: restarted, now: now.addingTimeInterval(7200)) { await delivered.add($0) }
        XCTAssertEqual(try restarted.storage(script.id)["checks"], "2")
        let notices = await delivered.values
        XCTAssertEqual(notices.map(\.id), ["v2"])
        let rendered = try await runner.run(script: script, store: store)
        XCTAssertEqual(rendered.entries.first?.view.text, "v2")
    }
    func testDeliveryFailureRetainsOutboxWithoutRepeatingPoll() async throws {
        let (store, script, root) = try fixture(source(hook))
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await OrbitAppletRunner().check(script: script, store: store, now: now) { _ in throw OrbitWidgetError("Delivery failed") }
            XCTFail("Expected delivery failure")
        } catch { }
        XCTAssertEqual(try store.pollingState(script.id)?.pending.count, 1)
        XCTAssertEqual(try store.pollingState(script.id)?.lastSuccess, now)
        let delivered = Notices()
        try await OrbitAppletRunner().check(script: script, store: store, now: now.addingTimeInterval(60)) { await delivered.add($0) }
        XCTAssertEqual(try store.storage(script.id)["checks"], "1")
        XCTAssertEqual(try store.pollingState(script.id)?.pending.count, 0)
        let count = await delivered.values.count
        XCTAssertEqual(count, 1)
    }
    func testFailedPollingRollsBackStateAndNotificationAndBacksOff() async throws {
        for body in [hook + "\nmodule.exports.poll=ctx=>{ctx.storage.set('bad',1);ctx.notify({id:'bad',title:'Bad',body:''});JSON.parse('broken')};",
                     "module.exports.poll=async ctx=>{ctx.storage.set('bad',1);await fetch('https://unapproved.example/data')};",
                     "module.exports.poll=ctx=>{ctx.notify({id:'',title:'Invalid',body:''})};",
                     "module.exports.poll=ctx=>{ctx.notify({id:'a',title:'A',body:''});ctx.notify({id:'b',title:'B',body:''})};"] {
            let (store, script, root) = try fixture(source(body))
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try await OrbitAppletRunner().check(script: script, store: store, now: now) { _ in XCTFail("Delivered failed output") }
                XCTFail("Accepted invalid poll")
            } catch { }
            XCTAssertTrue(try store.storage(script.id).isEmpty)
            let state = try XCTUnwrap(store.pollingState(script.id))
            XCTAssertNil(state.lastSuccess); XCTAssertNotNil(state.failure); XCTAssertTrue(state.pending.isEmpty)
            XCTAssertEqual(state.nextAttempt, now.addingTimeInterval(900))
        }
    }
    func testConsentAndStaleUpdateRemovalPreventExecutionAndDelivery() async throws {
        let (store, script, root) = try fixture(source(hook))
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = OrbitAppletRunner()
        try await runner.check(script: script, store: store, now: now) { _ in }
        let changed = source("throw new Error('never run stale source');")
        try store.install(changed)
        let checked = try await runner.check(script: script, store: store, now: now.addingTimeInterval(8000)) { _ in XCTFail("Stale delivery") }
        XCTAssertFalse(checked)
        let next = try await runner.nextCheck(store: store, now: now)
        XCTAssertEqual(next, now)
        try store.remove(script.id)
        XCTAssertNil(try store.pollingState(script.id))
        XCTAssertTrue(try store.storage(script.id).isEmpty)
        let noConsent = try OrbitAppletDefinition.widgetScript(source(hook, metadata: ",\"pollHours\":2"))
        do { _ = try await OrbitAppletRuntime.run(script: noConsent, storage: [:], poll: true); XCTFail("Notification without consent") } catch { }
    }
    func testPollDoesNotRenderOrRunUpdateAndNotifyIsPollOnly() async throws {
        let script = try OrbitAppletDefinition.widgetScript(source(hook + "\nmodule.exports.update=()=>{throw Error('update')}; module.exports.render=()=>{throw Error('render')};"))
        let result = try await OrbitAppletRuntime.run(script: script, storage: [:], poll: true, now: now)
        XCTAssertEqual(result.notifications?.first?.id, "v2")
        let foreground = try OrbitAppletDefinition.widgetScript(source("module.exports.update=ctx=>ctx.notify({id:'x',title:'X',body:''}); module.exports.render=()=>({type:'text'});"))
        do { _ = try await OrbitAppletRuntime.run(script: foreground, storage: [:]); XCTFail("Foreground notify allowed") } catch { }
    }
}

private actor Notices {
    var values: [OrbitAppletNotification] = []
    func add(_ value: OrbitAppletNotification) { values.append(value) }
}
