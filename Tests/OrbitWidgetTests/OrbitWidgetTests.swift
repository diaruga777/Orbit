import XCTest
@testable import OrbitWidgets

final class OrbitWidgetTests: XCTestCase {
    private func source(_ code: String = "module.exports.render = () => ({type:'text',text:'Hello'});", domains: String = "[]", id: String = "test-widget") -> String {
        "/* orbit-widget\n{\"id\":\"\(id)\",\"name\":\"Test Widget\",\"domains\":\(domains),\"refreshMinutes\":30}\n*/\n" + code
    }
    func testManifestIsParsedWithoutExecutingTopLevelCode() throws {
        let definition = try OrbitWidgetDefinition.parse(source("throw new Error('never run');"))
        XCTAssertEqual(definition.id, "test-widget")
        XCTAssertThrowsError(try OrbitWidgetDefinition.parse(source(id: "../../escape")))
        XCTAssertThrowsError(try OrbitWidgetDefinition.parse("module.exports = {};"))
        XCTAssertThrowsError(try OrbitWidgetDefinition.parse(source() + String(repeating: " ", count: 130 * 1024)))
    }
    func testExactHTTPSNetworkGrantRejectsCredentialsPortsWildcardsAndPrivateLiteralHosts() throws {
        let definition = try OrbitWidgetDefinition.parse(source(domains: "[\"api.example.com\"]"))
        XCTAssertTrue(definition.permits(URL(string: "https://api.example.com/trains")!))
        for address in ["http://api.example.com", "https://sub.api.example.com", "https://api.example.com.evil.com", "https://user:password@api.example.com", "https://api.example.com:8443", "https://127.0.0.1"] { XCTAssertFalse(definition.permits(URL(string: address)!)) }
        for domain in ["*.example.com", "127.0.0.1", "router.local", "api.example.com/path", "api..example.com"] { XCTAssertThrowsError(try OrbitWidgetDefinition.parse(source(domains: "[\"\(domain)\"]"))) }
    }
    func testHooksPersistJSONAndProduceFutureTimeline() async throws {
        let code = #"""
        module.exports = {
          async update(ctx) { ctx.storage.set('count', ctx.storage.get('count', 0) + 1); },
          render(ctx) { return {type:'text', text:String(ctx.storage.get('count'))}; },
          timeline(ctx) { return [{date:new Date(ctx.now.getTime()+60000).toISOString(),view:{type:'text',text:'Next'}}]; }
        };
        """#
        let script = try OrbitWidgetScript(source: source(code))
        let output = try await OrbitWidgetRuntime.run(script: script, storage: [:], family: "medium")
        XCTAssertEqual(output.entries.count, 2); XCTAssertEqual(output.entries.first?.view.text, "1"); XCTAssertEqual(output.storage["count"], "1")
        let second = try await OrbitWidgetRuntime.run(script: script, storage: output.storage, family: "medium")
        XCTAssertEqual(second.entries.first?.view.text, "2")
    }
    func testInvalidLayoutAndBackwardsTimelineAreRejected() async throws {
        for code in ["module.exports.render=()=>({type:'webview'});", "module.exports.render=()=>({type:'text',text:'x',size:999});", "module.exports.render=()=>({type:'text',text:'x'});module.exports.timeline=ctx=>[{date:new Date(ctx.now.getTime()-120000).toISOString(),view:{type:'text'}}];"] {
            do { _ = try await OrbitWidgetRuntime.run(script: OrbitWidgetScript(source: source(code)), storage: [:], family: "small"); XCTFail("Invalid result accepted") } catch { }
        }
    }
    func testDisallowedFetchFailsBeforeAnyNetworkRequest() async throws {
        let code = "module.exports.update=async()=>{await fetch('https://not-approved.example/data')}; module.exports.render=()=>({type:'text',text:'x'});"
        do { _ = try await OrbitWidgetRuntime.run(script: OrbitWidgetScript(source: source(code)), storage: [:], family: "small"); XCTFail("Missing grant accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("allowed HTTPS")) }
    }
    func testStorageIsolationReplacementAndRemovalRejectStaleOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OrbitWidgetStore(directory: root)
        let a = try OrbitWidgetScript(source: source("module.exports.render=()=>({type:'text',text:'A'});"))
        try store.install(a.source)
        let output = try await OrbitWidgetRuntime.run(script: a, storage: ["a": "1"], family: "small")
        try store.save(output, script: a, family: "small")
        XCTAssertEqual(try store.storage(a.id)["a"], "1"); XCTAssertEqual(try store.storage("other"), [:])
        try store.install(source("module.exports.render=()=>({type:'text',text:'B'});"))
        XCTAssertThrowsError(try store.save(output, script: a, family: "small"))
        XCTAssertEqual(try store.scripts().count, 1)
        try store.remove(a.id)
        XCTAssertNil(try store.script(a.id)); XCTAssertNil(try store.output(a.id, family: "small")); XCTAssertTrue(try store.storage(a.id).isEmpty)
        XCTAssertThrowsError(try store.script("../../escape"))
    }
    func testStorageQuotaIsEnforced() async throws {
        let code = "module.exports.update=ctx=>ctx.storage.set('large','x'.repeat(70000));module.exports.render=()=>({type:'text',text:'x'});"
        do { _ = try await OrbitWidgetRuntime.run(script: OrbitWidgetScript(source: source(code)), storage: [:], family: "small"); XCTFail("Quota exceeded") } catch { }
    }
}
