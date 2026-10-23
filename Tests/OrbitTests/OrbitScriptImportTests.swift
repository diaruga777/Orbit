import XCTest
import OrbitWidgets
@testable import OrbitHost

final class OrbitScriptImportTests: XCTestCase {
    private let widget = "/* orbit-widget\n{\"id\":\"weather\",\"name\":\"Weather\",\"domains\":[],\"refreshMinutes\":30}\n*/\nthrow new Error('never evaluate imports');"
    private func call(_ host: OrbitHost, _ method: String, _ params: [String: Any] = [:], peer: String? = nil) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        let response = await host.handle(data, peer: peer)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }
    func testInferredImportCopiesToSelectedFoldersAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var host: OrbitHost? = try OrbitHost(root: root.appendingPathComponent("state"))
        let selected = root.appendingPathComponent("selected"); try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let setup = try await call(host!, "setup_folder", ["path": selected.path]); XCTAssertNil(setup["error"])
        let source = root.appendingPathComponent("misleading-name.js"); try Data(OrbitAppletExport.blank.utf8).write(to: source)
        let added = try await call(host!, "script_import", ["path": source.path])
        XCTAssertEqual((added["result"] as? [String: Any])?["kind"] as? String, "applet")
        XCTAssertEqual(try String(contentsOf: selected.appendingPathComponent("Applets/my-applet.js"), encoding: .utf8), OrbitAppletExport.blank)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), OrbitAppletExport.blank)
        host = nil
        let restarted = try OrbitHost(root: root.appendingPathComponent("state"))
        let listed = try await call(restarted, "applets")
        XCTAssertEqual((listed["result"] as? [[String: String]])?.count, 1)
        // Leading dots are valid manifest IDs and must remain discoverable after copying.
        try Data(widget.replacingOccurrences(of: "weather", with: ".weather").utf8).write(to: source)
        let hidden = try await call(restarted, "script_import", ["path": source.path]); XCTAssertNil(hidden["error"])
        let widgets = try await call(restarted, "widgets")
        XCTAssertEqual((widgets["result"] as? [[String: String]])?.first?["id"], ".weather")
    }
    func testFolderAddsUpdatesAndBadFilesDoNotBlockPhoneDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        _ = try await call(host, "script_status")
        // Inference follows content even when the file was placed in the other folder.
        let source = root.appendingPathComponent("Applets/forecast.js")
        try Data(widget.utf8).write(to: source)
        try Data("broken".utf8).write(to: root.appendingPathComponent("Widgets/broken.js"))
        try Data(repeating: 65, count: 128 * 1024 + 1).write(to: root.appendingPathComponent("Widgets/large.js"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Widgets/link.js"), withDestinationURL: source)
        await host.scanScripts()
        await host.openPairing(); try await host.trust("phone")
        var result = try await call(host, "widgets", peer: "phone")
        XCTAssertEqual((result["result"] as? [[String: String]])?.first?["source"], widget)
        let state = try await call(host, "script_status")
        XCTAssertEqual((state["result"] as? [String: Any])?["issues"].flatMap { $0 as? [String] }?.count, 3)
        let updated = widget + "\n// updated"
        try Data(updated.utf8).write(to: source, options: .atomic)
        result = try await call(host, "widgets", peer: "phone")
        XCTAssertEqual((result["result"] as? [[String: String]])?.first?["source"], updated)
        let forbidden = try await call(host, "script_import", ["path": source.path], peer: "phone"); XCTAssertNotNil(forbidden["error"])
        let folderDenied = try await call(host, "script_folder", ["kind": "widget", "path": root.path], peer: "phone"); XCTAssertNotNil(folderDenied["error"])
        _ = try await call(host, "widget_remove", ["id": "weather"])
        result = try await call(host, "widgets", peer: "phone")
        XCTAssertEqual((result["result"] as? [[String: String]])?.count, 0)
    }
    func testLegacyQueueMigratesOnlyOnceAndRemovedFilesStayRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), selected = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: state.appendingPathComponent("Applets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try Data(OrbitAppletExport.blank.utf8).write(to: state.appendingPathComponent("Applets/old-name.js"))
        var config = OrbitConfiguration(); config.allowedRoots = [selected.path]
        try JSONEncoder().encode(config).write(to: state.appendingPathComponent("config.json"))
        var host: OrbitHost? = try OrbitHost(root: state)
        var listed = try await call(host!, "applets")
        XCTAssertEqual((listed["result"] as? [[String: String]])?.count, 1)
        _ = try await call(host!, "applet_remove", ["id": "my-applet"])
        host = nil
        let restarted = try OrbitHost(root: state)
        listed = try await call(restarted, "applets")
        XCTAssertEqual((listed["result"] as? [[String: String]])?.count, 0)
    }
    func testFolderChangePreservesScriptsWithoutOverwritingUserFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root.appendingPathComponent("state"))
        let source = root.appendingPathComponent("input.js"); try Data(widget.utf8).write(to: source)
        _ = try await call(host, "widget_add", ["path": source.path])
        let folder = root.appendingPathComponent("new"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let own = widget + "\n// user version"; try Data(own.utf8).write(to: folder.appendingPathComponent("weather.js"))
        let selected = try await call(host, "script_folder", ["kind": "widget", "path": folder.path]); XCTAssertNil(selected["error"])
        let listed = try await call(host, "widgets")
        XCTAssertEqual((listed["result"] as? [[String: String]])?.first?["source"], own)
        let next = widget + "\n// import update"; try Data(next.utf8).write(to: source)
        _ = try await call(host, "script_import", ["path": source.path])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("weather.js"), encoding: .utf8), next)
    }
}
