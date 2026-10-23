import XCTest
@testable import OrbitWidgets

final class OrbitScriptInboxTests: XCTestCase {
    private func source(_ suffix: String = "") -> String {
        "/* orbit-applet\n{\"id\":\"inbox\",\"name\":\"Inbox\",\"domains\":[]}\n*/\nthrow new Error('must not run');\n" + suffix
    }
    func testReceivingPersistsWithoutInstallingOrChangingPrivateDataAndRequiresFreshConsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OrbitWidgetStore(directory: root, applets: true)
        try store.receive([source()], origin: "mac")
        XCTAssertTrue(try store.scripts().isEmpty)
        let restarted = OrbitWidgetStore(directory: root, applets: true)
        XCTAssertEqual(try restarted.pendingScripts().map(\.source), [source()])
        try restarted.approvePending(source())
        XCTAssertEqual(try restarted.script("inbox")?.source, source())
        let installed = try XCTUnwrap(restarted.script("inbox"))
        let output = OrbitWidgetOutput(entries: [], storage: ["private": "kept"], updatedAt: Date())
        try restarted.save(output, script: installed, family: "large")
        try restarted.receive([source()], origin: "mac")
        XCTAssertTrue(try restarted.pendingScripts().isEmpty)
        try restarted.receive([source("// update")], origin: "mac")
        XCTAssertEqual(try restarted.script("inbox")?.source, source())
        try restarted.receive([source("// latest")], origin: "mac")
        XCTAssertThrowsError(try restarted.approvePending(source("// update")))
        XCTAssertEqual(try restarted.script("inbox")?.source, source())
        try restarted.approvePending(source("// latest"))
        XCTAssertEqual(try restarted.script("inbox")?.source, source("// latest"))
        XCTAssertEqual(try restarted.storage("inbox"), ["private": "kept"])
    }
    func testDismissalNewDigestInvalidSnapshotAndPeerChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OrbitWidgetStore(directory: root, applets: true)
        try store.receive([source()], origin: "mac")
        try store.dismissPending(source())
        try store.receive([source()], origin: "mac")
        XCTAssertTrue(try store.pendingScripts().isEmpty)
        try store.receive([source("// update")], origin: "mac")
        XCTAssertEqual(try store.pendingScripts().count, 1)
        XCTAssertThrowsError(try store.receive(["bad"], origin: "mac"))
        XCTAssertEqual(try store.pendingScripts().first?.source, source("// update"))
        try store.receive([source()], origin: "another-mac")
        XCTAssertEqual(try store.pendingScripts().first?.source, source())
        try store.receive([], origin: "another-mac")
        XCTAssertTrue(try store.pendingScripts().isEmpty)
    }
    func testFileTypeInferenceAndBoundedReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("wrong-name.JS")
        try Data(source().utf8).write(to: file)
        XCTAssertEqual(try OrbitJavaScriptFile(url: file).kind, .applet)
        try Data(repeating: 65, count: OrbitWidgetDefinition.maximumSourceBytes + 1).write(to: file)
        XCTAssertThrowsError(try OrbitJavaScriptFile(url: file))
        XCTAssertThrowsError(try OrbitJavaScriptFile(url: root))
    }
}
