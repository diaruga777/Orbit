import XCTest
import OrbitCore
@testable import OrbitHost

final class OrbitAppDiagnosticCollectorTests: XCTestCase {
    private actor Source {
        var available = false
        var calls = 0
        let files: [Data]
        init(_ files: [Data]) { self.files = files }
        func enable() { available = true }
        func read(_ app: CodeInstalledApp) throws -> [Data] {
            calls += 1
            guard available else { throw CodeFailure("private native transcript") }
            return files
        }
    }
    func testAutomaticCollectionBackoffReconnectRestartAndAppIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceJournal = OrbitDiagnostics(directory: root.appendingPathComponent("source"))
        sourceJournal.record("screen", "settings")
        sourceJournal.record("action", "settings.save")
        sourceJournal.record("error", "save.failed", ["token": "must-not-leak"])
        let data = try Data(contentsOf: sourceJournal.directory.appendingPathComponent("events.jsonl"))
        let source = Source([data])
        let destination = root.appendingPathComponent("received")
        var collector = try OrbitAppDiagnosticCollector(root: destination, readFiles: { try await source.read($0) })
        let app = CodeInstalledApp(deviceID: "phone-1", bundleID: "org.test.app", name: "App", version: "1", build: "2", installedAt: Date())
        let now = Date()
        await collector.collect([app], now: now)
        var list = await collector.list()
        XCTAssertEqual(list.first?.state, "unavailable"); XCTAssertNil(list.first?.lastSuccess)
        await source.enable()
        await collector.collect([app], now: now.addingTimeInterval(10))
        let callsBeforeRetry = await source.calls
        XCTAssertEqual(callsBeforeRetry, 1)
        await collector.collect([app], now: now.addingTimeInterval(61))
        list = await collector.list()
        XCTAssertEqual(list.first?.state, "receiving")
        let id = OrbitAppDiagnosticCollector.id(app)
        let events = try await collector.events(app: id, maximum: 100)
        XCTAssertEqual(events.map(\.name), ["settings", "settings.save", "save.failed"])
        XCTAssertEqual(events.last?.fields["token"], "[redacted]")
        collector = try OrbitAppDiagnosticCollector(root: destination, readFiles: { try await source.read($0) })
        await collector.collect([app], now: now.addingTimeInterval(80))
        let repeated = try await collector.events(app: id, maximum: 100)
        XCTAssertEqual(repeated, events)
        // Late old rotation contents must not reorder source actions.
        let lateRoot = root.appendingPathComponent("late")
        let lateData = try JSONEncoder().encode([events[2], events[0], events[1]])
        let lateEvents = try JSONDecoder().decode([OrbitDiagnosticEvent].self, from: lateData)
        let lateFiles = try lateEvents.map { try JSONEncoder().encode($0) + Data([10]) }.reduce(Data(), +)
        let lateCollector = try OrbitAppDiagnosticCollector(root: lateRoot, readFiles: { _ in [lateFiles] })
        await lateCollector.collect([app], now: now)
        let reordered = try await lateCollector.events(app: id, maximum: 100)
        XCTAssertEqual(reordered.map(\.name), events.map(\.name))
        var other = app; other.deviceID = "phone-2"
        XCTAssertNotEqual(id, OrbitAppDiagnosticCollector.id(other))
        other = app; other.bundleID = "org.test.other"
        XCTAssertNotEqual(id, OrbitAppDiagnosticCollector.id(other))
        do { _ = try await collector.events(app: "../escape", maximum: 100); XCTFail("Accepted traversal") } catch { }
        let metadata = try String(contentsOf: destination.appendingPathComponent("status.json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("private native transcript"))
    }
    func testPartialLineReplayRotationAndBounds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = OrbitDiagnostics(directory: root.appendingPathComponent("source"))
        source.record("action", "first")
        var first = try Data(contentsOf: source.directory.appendingPathComponent("events.jsonl"))
        let received = OrbitDiagnostics(directory: root.appendingPathComponent("received"))
        source.record("action", "second")
        let complete = try Data(contentsOf: source.directory.appendingPathComponent("events.jsonl"))
        first += complete.dropFirst(first.count).prefix(40)
        try OrbitAppDiagnosticCollector.importFiles([first], into: received)
        XCTAssertEqual(received.recent().map(\.name), ["first"])
        try OrbitAppDiagnosticCollector.importFiles([complete, complete], into: received)
        XCTAssertEqual(received.recent().map(\.name), ["first", "second"])
        XCTAssertThrowsError(try OrbitAppDiagnosticCollector.importFiles([Data("invalid-json\n".utf8)], into: received))
        XCTAssertThrowsError(try OrbitAppDiagnosticCollector.importFiles(Array(repeating: Data(), count: 5), into: received))
        XCTAssertThrowsError(try OrbitAppDiagnosticCollector.importFiles([Data(repeating: 0, count: 1024 * 1024 + 16385)], into: received))
    }
    func testPackagedResourcesTakePrecedenceOverCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packaged = root.appendingPathComponent("Orbit_OrbitHost.bundle/AppletHost")
        try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: true)
        XCTAssertEqual(OrbitAppletExport.template(in: root)?.path, packaged.path)
    }
    func testInstrumentationSourcesAreAvailableOnlyOnMac() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let request = try JSONSerialization.data(withJSONObject: ["method": "app_debug_setup"])
        let reply = try JSONSerialization.jsonObject(with: await host.handle(request)) as? [String: Any]
        let files = (reply?["result"] as? [String: Any])?["files"] as? [String: String]
        XCTAssertEqual(files?.count, 3)
        XCTAssertNotNil(files?["OrbitAppDiagnostics.swift"])
        await host.openPairing(); try await host.trust("phone")
        let denied = try JSONSerialization.jsonObject(with: await host.handle(request, peer: "phone")) as? [String: Any]
        XCTAssertNotNil(denied?["error"])
        let read = try JSONSerialization.data(withJSONObject: ["method": "diagnostics", "params": ["app": "../escape"]])
        let remote = try JSONSerialization.jsonObject(with: await host.handle(read, peer: "phone")) as? [String: Any]
        XCTAssertNotNil(remote?["error"])
    }
}
