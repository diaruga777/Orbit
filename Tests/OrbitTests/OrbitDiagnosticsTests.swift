import XCTest
import OrbitCore
import OrbitWire
@testable import OrbitHost

final class OrbitDiagnosticsTests: XCTestCase {
    func testRotationRedactionRestartAndDeduplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = OrbitDiagnostics(directory: root, fileBytes: 4096, fileCount: 2)
        for index in 0..<90 { journal.record("rpc", "event", ["index": String(index), "detail": String(repeating: "a ", count: 150)]) }
        journal.record("rpc", "failure", ["password": "never-store-me", "error": "token=secret-value user@example.com https://user:password@host.test/path /Users/somebody/private.txt"])
        let events = journal.recent(maximum: 500)
        XCTAssertLessThan(events.count, 90)
        XCTAssertEqual(events.last?.fields["password"], "[redacted]")
        let bytes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map { try Data(contentsOf: $0) }.reduce(Data(), +)
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in ["never-store-me", "secret-value", "user@example.com", "somebody"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertLessThanOrEqual(bytes.count, 8192)
        let restarted = OrbitDiagnostics(directory: root, fileBytes: 4096, fileCount: 2)
        try restarted.append(events)
        XCTAssertEqual(restarted.recent(maximum: 500), events)
        XCTAssertTrue(restarted.events(after: events.last!.id).isEmpty)
        XCTAssertEqual(restarted.events(after: "rotated-away", maximum: 1).first, events.first)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("events.jsonl").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
    func testConcurrentWritersProduceWholeEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = OrbitDiagnostics(directory: root)
        DispatchQueue.concurrentPerform(iterations: 100) { index in journal.record("test", "concurrent", ["index": String(index)]) }
        let events = journal.recent(maximum: 500)
        XCTAssertEqual(events.compactMap(\.sequence), Array(1...100).map(UInt64.init))
        XCTAssertEqual(events.count, 100); XCTAssertEqual(Set(events.map(\.id)).count, 100)
    }
    func testPhoneUploadIsAuthenticatedBoundedAndIdempotentAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let phoneRoot = root.appendingPathComponent("phone")
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = try DeviceID(bytes: Data(repeating: 7, count: 32)).description
        let journal = OrbitDiagnostics(directory: phoneRoot)
        journal.record("action", "build_pressed", ["target": "fixture"])
        let events = try JSONSerialization.jsonObject(with: JSONEncoder().encode(journal.events()))
        var host: OrbitHost? = try OrbitHost(root: root)
        func request(_ host: OrbitHost, _ method: String, _ params: [String: Any] = [:], peer: String? = nil) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
            return try JSONSerialization.jsonObject(with: await host.handle(data, peer: peer)) as! [String: Any]
        }
        let rejected = try await request(host!, "diagnostics_upload", ["events": events], peer: phone)
        XCTAssertNotNil(rejected["error"])
        await host!.openPairing(); try await host!.trust(phone)
        let uploaded = try await request(host!, "diagnostics_upload", ["events": events], peer: phone)
        XCTAssertEqual((uploaded["result"] as? [String: Any])?["acknowledged"] as? String, journal.events().last?.id)
        host = nil
        let restarted = try OrbitHost(root: root)
        _ = try await request(restarted, "diagnostics_upload", ["events": events], peer: phone)
        let received = try await request(restarted, "diagnostics", ["phone": phone])
        XCTAssertEqual(((received["result"] as? [String: Any])?["events"] as? [Any])?.count, 1)
        let remoteRead = try await request(restarted, "diagnostics", peer: phone)
        XCTAssertNotNil(remoteRead["error"])
        let oversized = try await request(restarted, "diagnostics_upload", ["events": [String(repeating: "x", count: 129 * 1024)]], peer: phone)
        XCTAssertNotNil(oversized["error"])
        let traversal = try await request(restarted, "diagnostics", ["phone": "../escape"])
        XCTAssertNotNil(traversal["error"])
    }
}
