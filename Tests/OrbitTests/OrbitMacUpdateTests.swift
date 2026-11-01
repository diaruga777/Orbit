import XCTest
import OrbitCore
@testable import OrbitHost
@testable import OrbitMac

final class OrbitMacUpdateTests: XCTestCase {
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("OrbitMacUpdateTests-" + UUID().uuidString) }
    func testMaintenanceBlocksNewBuildsUntilReleased() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let service = try CodeService(root: root)
        try await service.beginMacUpdate()
        let request = try JSONEncoder().encode(CodeRequest(.runOnDevice))
        let gated = try JSONDecoder().decode(CodeResponse.self, from: await service.handle(request))
        XCTAssertTrue(gated.error?.contains("Orbit Mac is updating") == true)
        await service.endMacUpdate()
        let normal = try JSONDecoder().decode(CodeResponse.self, from: await service.handle(request))
        XCTAssertFalse(normal.error?.contains("Orbit Mac is updating") == true)
    }
    func testInterruptedWorkerSurvivesRestartAndCannotClaimInstallationSuccess() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("MacUpdate")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let job = directory.appendingPathComponent("job.json")
        try JSONSerialization.data(withJSONObject: ["id": "durable", "state": "building", "pid": Int32.max, "revision": "uninstalled"]).write(to: job)
        let first = await OrbitMacUpdate(root: root).status()
        XCTAssertEqual(first["id"] as? String, "durable")
        XCTAssertEqual(first["state"] as? String, "failed")
        let restarted = await OrbitMacUpdate(root: root).status()
        XCTAssertEqual(restarted["state"] as? String, "failed")
        XCTAssertNotEqual(restarted["state"] as? String, "succeeded")
    }
    func testUntrustedPhoneCannotStartMacUpdateAndRemoteCannotPrepare() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let rejected = await host.handle(Data(#"{"method":"mac_update"}"#.utf8), peer: "untrusted")
        XCTAssertTrue(String(decoding: rejected, as: UTF8.self).contains("Approve this phone"))
        await host.openPairing(); try await host.trust("trusted")
        let prepare = await host.handle(Data(#"{"method":"mac_update_prepare"}"#.utf8), peer: "trusted")
        XCTAssertTrue(String(decoding: prepare, as: UTF8.self).contains("Mac section"))
        let status = await host.handle(Data(#"{"method":"mac_update_status"}"#.utf8), peer: "trusted")
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: status) as? [String: Any])?["result"])
        let targets = await host.handle(Data(#"{"method":"targets"}"#.utf8))
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: targets) as? [String: Any])?["result"] as? [Any])?.count, 0)
    }
}
