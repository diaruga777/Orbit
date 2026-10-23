import XCTest
@testable import OrbitWidgets

final class OrbitAppletTests: XCTestCase {
    private func source(_ body: String, domains: String = "[]") -> String {
        "/* orbit-applet\n{\"id\":\"counter\",\"name\":\"Counter\",\"domains\":\(domains)}\n*/\n" + body
    }
    func testManifestIsInertAndSeparateFromWidgets() throws {
        let source = source("throw new Error('untrusted');")
        XCTAssertEqual(try OrbitAppletDefinition.parse(source).id, "counter")
        XCTAssertThrowsError(try OrbitWidgetDefinition.parse(source))
        XCTAssertThrowsError(try OrbitAppletDefinition.parse("/* orbit-applet\n{\"id\":\"../bad\",\"name\":\"Bad\",\"domains\":[]}\n*/"))
        XCTAssertThrowsError(try OrbitAppletDefinition.parse(self.source("", domains: "[\"*.example.com\"]")))
    }
    func testActionsReceiveInputsAndPersistAcrossFreshVMs() async throws {
        let script = try OrbitAppletDefinition.widgetScript(source(#"""
        module.exports = {
          update(ctx) { ctx.storage.set('launches',ctx.storage.get('launches',0)+1); },
          action(ctx,event) { ctx.storage.set('name',event.values.name); ctx.storage.set('count',ctx.storage.get('count',0)+1); },
          render(ctx) { return {type:'vstack',children:[
            {type:'text',text:ctx.storage.get('name','Hello')},
            {type:'textfield',key:'name',value:'',text:'Name',action:'save'},
            {type:'toggle',key:'enabled',isOn:true,text:'Enabled',action:'toggle'},
            {type:'button',text:'Save',action:'save'}]}; }
        };
        """#))
        let initial = try await OrbitAppletRuntime.run(script: script, storage: [:])
        XCTAssertEqual(initial.storage["launches"], "1"); XCTAssertEqual(initial.entries.count, 1)
        let action = try await OrbitAppletRuntime.run(script: script, storage: initial.storage, event: .init(action: "save", values: ["name": "Ada"]))
        XCTAssertEqual(action.entries[0].view.children?[0].text, "Ada")
        XCTAssertEqual(action.storage["launches"], "1"); XCTAssertEqual(action.storage["count"], "1")
        let next = try await OrbitAppletRuntime.run(script: script, storage: action.storage)
        XCTAssertEqual(next.storage["launches"], "2"); XCTAssertEqual(next.storage["name"], "\"Ada\"")
    }
    func testMalformedControlsNetworkAndFailedActionsDoNotCommit() async throws {
        for body in [
            "module.exports.render=()=>({type:'button',text:'Missing action'});",
            "module.exports.render=()=>({type:'textfield',action:'save'});",
            "module.exports.render=()=>({type:'webview'});",
            "module.exports.update=async()=>{await fetch('https://not-approved.example')}; module.exports.render=()=>({type:'text'});",
            "module.exports.action=ctx=>{ctx.storage.set('bad',true);throw new Error('failed')}; module.exports.render=()=>({type:'text'});"
        ] {
            let script = try OrbitAppletDefinition.widgetScript(source(body))
            do {
                _ = try await OrbitAppletRuntime.run(script: script, storage: [:], event: body.contains("exports.action") ? .init(action: "save") : nil)
                XCTFail("Invalid applet accepted")
            } catch { }
        }
    }
    func testUpdatePreservesPrivateStateAndRejectsStaleInvocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OrbitWidgetStore(directory: directory, applets: true)
        let script = try OrbitAppletDefinition.widgetScript(source("module.exports.render=()=>({type:'button',text:'Old',action:'tap'});"))
        try store.install(script.source)
        let output = try await OrbitAppletRuntime.run(script: script, storage: ["count": "3"])
        try store.save(output, script: script, family: "large")
        try store.install(source("module.exports.render=()=>({type:'text',text:'New'});"))
        XCTAssertThrowsError(try store.save(output, script: script, family: "large"))
        XCTAssertEqual(try store.storage(script.id)["count"], "3")
        XCTAssertNil(try store.output(script.id, family: "large"))
        try store.remove(script.id)
        XCTAssertTrue(try store.storage(script.id).isEmpty)
    }
}
