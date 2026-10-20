import XCTest
import OrbitCore
import OrbitWire
import OrbitTransport
@testable import OrbitHost
@testable import OrbitMac

final class OrbitHostTests: XCTestCase {
    func testSixDayCadenceDependsOnConfirmedInstallation() {
        let now = Date(timeIntervalSince1970: 2000000)
        var target = OrbitTarget(name: "App", project: CodeProject(path: "/repo/App.xcodeproj", scheme: "App"), deviceID: "phone", enabled: true)
        XCTAssertTrue(target.isDue(at: now))
        target.lastAttempt = now.addingTimeInterval(-60); XCTAssertFalse(target.isDue(at: now))
        target.lastAttempt = now.addingTimeInterval(-1801); XCTAssertTrue(target.isDue(at: now))
        target.lastSuccess = now.addingTimeInterval(-143 * 3600); XCTAssertFalse(target.isDue(at: now))
        target.lastSuccess = now.addingTimeInterval(-144 * 3600); XCTAssertTrue(target.isDue(at: now))
        target.jobID = "retained-job"; XCTAssertFalse(target.isDue(at: now))
    }
    func testPendingRequestAndSigningPolicySurviveRestart() throws {
        var project = CodeProject(path: "/repo/App.xcodeproj", scheme: "App")
        project.developmentTeam = "USERS_TEAM"; project.minimumProfileHours = 156
        var target = OrbitTarget(name: "App", project: project, deviceID: "phone")
        target.pendingRequest = CodeRequest(.overnightSubmit)
        let decoded = try JSONDecoder().decode(OrbitTarget.self, from: JSONEncoder().encode(target))
        XCTAssertEqual(decoded.pendingRequest?.id, target.pendingRequest?.id)
        XCTAssertEqual(decoded.project.developmentTeam, "USERS_TEAM")
        XCTAssertEqual(decoded.project.minimumProfileHours, 156)
        XCTAssertTrue(decoded.project.xcodeArguments.contains("DEVELOPMENT_TEAM=USERS_TEAM"))
    }
    func testGitHubInputCannotBecomeAnArbitraryCloneURL() throws {
        XCTAssertEqual(try OrbitGitHub.repository("https://github.com/example/app.git"), "example/app")
        XCTAssertEqual(try OrbitGitHub.repository("example/app"), "example/app")
        for input in ["https://evil.example/app", "https://github.com@evil.example/app", "../app", "owner/../app", "owner/app/extra", "--upload-pack=bad", "file:///tmp/repo", "https://user:password@github.com/owner/app"] {
            XCTAssertThrowsError(try OrbitGitHub.repository(input), input)
        }
    }
    func testUntrustedPeerCannotBrowseOrRunCommands() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let data = await host.handle(Data(#"{"method":"browse","params":{"path":"/"}}"#.utf8), peer: "stranger")
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(value?["error"])
        do { try await host.trust("stranger"); XCTFail("No pairing window was open") } catch { }
        await host.openPairing(); try await host.trust("phone")
        let restarted = try OrbitHost(root: root)
        let trusted = await restarted.isTrusted("phone"); XCTAssertTrue(trusted)
        let other = await restarted.isTrusted("stranger"); XCTAssertFalse(other)
    }
    func testForgetRevokesAndDoesNotReopenPairing() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root); await host.openPairing(); try await host.trust("phone")
        _ = await host.handle(Data(#"{"method":"forget"}"#.utf8))
        let trusted = await host.isTrusted("phone"); XCTAssertFalse(trusted)
        do { try await host.trust("new-phone"); XCTFail("Forgetting must close pairing") } catch { }
    }
    func testAddRequiresTrustBeforeInvokingXcode() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let data = await host.handle(Data(#"{"method":"target_add","params":{"project":"/tmp/App.xcodeproj","scheme":"App","deviceID":"phone"}}"#.utf8))
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue((value?["error"] as? String)?.contains("trust=true") == true)
    }
    func testFramingRejectsOversizeBeforeReadingPayload() async throws {
        let (reader, writer) = PipeByteStream.pair(); defer { reader.close(); writer.close() }
        try await writer.write(Data([0xff, 0xff, 0xff, 0xff]))
        do { _ = try await OrbitRPC.read(from: reader); XCTFail("Oversized frame accepted") } catch { }
    }
    func testFramingHandlesFragmentedPayload() async throws {
        let (reader, writer) = PipeByteStream.pair(); defer { reader.close(); writer.close() }
        let task = Task { try await OrbitRPC.read(from: reader) }
        try await writer.write(Data([0, 0])); try await writer.write(Data([0, 5])); try await writer.write(Data("he".utf8)); try await writer.write(Data("llo".utf8))
        let value = try await task.value; XCTAssertEqual(value, Data("hello".utf8))
    }
    func testProfileRotationOnlySelectsMatchingExpiringAutomaticDevelopmentProfile() {
        let now = Date()
        let profile: [String: Any] = ["ExpirationDate": now.addingTimeInterval(3600), "TeamIdentifier": ["TEAM"], "ProvisionedDevices": ["phone"], "Entitlements": ["get-task-allow": true, "application-identifier": "TEAM.com.example.app"]]
        XCTAssertTrue(CodeProfileRefresh.matches(profile, bundle: "com.example.app", team: "TEAM", device: "phone", minimumHours: 156, at: now))
        XCTAssertFalse(CodeProfileRefresh.matches(profile, bundle: "com.other.app", team: "TEAM", device: "phone", minimumHours: 156, at: now))
        XCTAssertFalse(CodeProfileRefresh.matches(profile, bundle: "com.example.app", team: "OTHER", device: "phone", minimumHours: 156, at: now))
        XCTAssertFalse(CodeProfileRefresh.matches(profile, bundle: "com.example.app", team: "TEAM", device: "different-phone", minimumHours: 156, at: now))
        var fresh = profile; fresh["ExpirationDate"] = now.addingTimeInterval(168 * 3600)
        XCTAssertFalse(CodeProfileRefresh.matches(fresh, bundle: "com.example.app", team: "TEAM", device: "phone", minimumHours: 156, at: now))
    }
    func testDumbpipePairingCodePreservesPinnedIdentity() throws {
        let id = try DeviceID(bytes: Data(repeating: 42, count: 32))
        let endpoint = id.bytes.map { String(format: "%02x", $0) }.joined()
        let original = OrbitPairingCode(deviceID: id, addresses: [.dumbpipe(endpoint: endpoint)])
        let restored = try OrbitPairingCode(string: original.text)
        XCTAssertEqual(restored.deviceID, id); XCTAssertEqual(restored.addresses, original.addresses)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("OrbitTests-" + UUID().uuidString) }
}
