import XCTest
import OrbitCore
@testable import OrbitHost

final class OrbitSetupTests: XCTestCase {
    func testSetupResumesWithoutSecrets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = OrbitSetup(root: root)
        var state = OrbitSetupState(); state.step = .phone; state.teamID = "ABCDEFGHIJ"; state.bundlePrefix = "dev.orbit.test"; state.deviceID = "phone"
        try await setup.save(state)
        let restored = try await OrbitSetup(root: root).load()
        XCTAssertEqual(restored.step, .phone); XCTAssertEqual(restored.teamID, state.teamID)
        let text = try String(contentsOf: root.appendingPathComponent("setup.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("password")); XCTAssertFalse(text.contains("PrivateKey"))
    }
    func testOldSetupStepsMigrateAndKeepInstalledIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = OrbitSetup(root: root)
        for old in [OrbitSetupStep.agents, .install, .connect, .refresh] {
            var state = OrbitSetupState(); state.step = old
            state.bundlePrefix = "dev.orbit.keep"; state.installed = true
            state.installTargetID = "target"; state.installJobID = "job"
            try await setup.save(state)
            let restored = try await setup.load()
            XCTAssertEqual(restored.step, old == .agents ? .access : .phone)
            XCTAssertEqual(restored.bundlePrefix, "dev.orbit.keep")
            XCTAssertEqual(restored.installTargetID, "target")
            XCTAssertEqual(restored.installJobID, "job")
            XCTAssertTrue(restored.installed)
        }
        XCTAssertEqual(OrbitSetupStep.allCases, [.welcome, .tools, .access, .account, .phone, .complete])
    }
    func testDefaultFolderAndGeneratedIdentityPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = OrbitSetup(root: root)
        let state = OrbitSetupState()
        XCTAssertEqual(state.folder, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Orbit").path)
        XCTAssertTrue(OrbitSetupState.validPrefix(state.bundlePrefix))
        XCTAssertNotEqual(state.bundlePrefix, OrbitSetupState().bundlePrefix)
        XCTAssertNotEqual(state.folderApproved, true)
        try await setup.save(state)
        let restored = try await setup.load()
        XCTAssertEqual(restored.bundlePrefix, state.bundlePrefix)
        XCTAssertEqual(restored.folder, state.folder)
    }
    func testSigningTeamsReadNestedXcodeMetadataAndIgnoreInvalidIdentifiers() {
        let fixture: [String: Any] = ["account@example.invalid": [
            ["teamID": "ABCDEFGHIJ", "name": "Alex", "isFreeProvisioningTeam": true],
            ["teamID": "1234567890", "name": "Company"],
            ["teamID": "invalid", "name": "Ignore"],
            ["teamID": "ABCDEFGHIJ", "name": "Alex", "isFreeProvisioningTeam": true]
        ]]
        let teams = OrbitSetup.signingTeams(in: fixture)
        XCTAssertEqual(teams.count, 2)
        XCTAssertEqual(teams.first(where: { $0.id == "ABCDEFGHIJ" })?.name, "Alex (Personal Team)")
    }
    func testFolderConsentChangesCloneDestinationAndIsLocalOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = try JSONSerialization.data(withJSONObject: ["method": "setup_folder", "params": ["path": folder.path]])
        let denied = try JSONSerialization.jsonObject(with: await host.handle(request, peer: "phone")) as? [String: Any]
        XCTAssertNotNil(denied?["error"])
        let response = try JSONSerialization.jsonObject(with: await host.handle(request)) as? [String: Any]
        XCTAssertNil(response?["error"])
        let config = await host.configuration
        XCTAssertEqual(config.allowedRoots, [folder.resolvingSymlinksInPath().path])
        XCTAssertEqual(config.provider, "local")
    }
    func testPhoneReadinessRequiresSelectedPhysicalPhoneAndDeveloperMode() {
        var result: [String: Any] = ["hardwareProperties": ["udid": "phone", "reality": "physical"], "deviceProperties": ["developerModeStatus": "enabled"]]
        XCTAssertTrue(OrbitSetup.phoneReady(["result": result], expected: "phone"))
        XCTAssertFalse(OrbitSetup.phoneReady(["result": result], expected: "other"))
        result["deviceProperties"] = ["developerModeStatus": "disabled"]
        XCTAssertFalse(OrbitSetup.phoneReady(["result": result], expected: "phone"))
        result["hardwareProperties"] = ["udid": "phone", "reality": "simulated"]
        result["deviceProperties"] = ["developerModeStatus": "enabled"]
        XCTAssertFalse(OrbitSetup.phoneReady(["result": result], expected: "phone"))
    }
    func testPersonalNamespaceSurvivesProjectArgumentsWithoutShell() {
        XCTAssertTrue(OrbitSetupState.validTeam("ABCDEFGHIJ")); XCTAssertFalse(OrbitSetupState.validTeam("someone"))
        XCTAssertTrue(OrbitSetupState.validPrefix("dev.orbit.my-app")); XCTAssertFalse(OrbitSetupState.validPrefix("dev.orbit.;touch"))
        var project = CodeProject(path: "/tmp/Phone App/Orbit.xcodeproj", scheme: "Orbit"); project.bundlePrefix = "dev.orbit.myapp"
        XCTAssertTrue(project.xcodeArguments.contains("ORBIT_BUNDLE_PREFIX=dev.orbit.myapp"))
    }
    func testWidgetDeploymentIsLocalAndNeverRunsItsSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let script = root.appendingPathComponent("test.js")
        try "/* orbit-widget\n{\"id\":\"test\",\"name\":\"Test\",\"domains\":[],\"refreshMinutes\":30}\n*/\nthrow new Error('do not execute');".write(to: script, atomically: true, encoding: .utf8)
        func request(_ method: String, _ params: [String: Any] = [:]) throws -> Data { try JSONSerialization.data(withJSONObject: ["method": method, "params": params]) }
        let response = try JSONSerialization.jsonObject(with: await host.handle(request("widget_add", ["path": script.path]))) as? [String: Any]
        XCTAssertNil(response?["error"])
        let listing = try JSONSerialization.jsonObject(with: await host.handle(request("widgets"))) as? [String: Any]
        XCTAssertEqual((listing?["result"] as? [[String: String]])?.first?["id"], "test")
        let rejected = try JSONSerialization.jsonObject(with: await host.handle(request("widget_add", ["path": script.path]), peer: "unknown")) as? [String: Any]
        XCTAssertNotNil(rejected?["error"])
    }
}
