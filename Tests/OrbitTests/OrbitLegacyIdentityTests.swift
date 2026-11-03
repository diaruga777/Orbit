import XCTest
import OrbitCore
@testable import OrbitHost
@testable import OrbitMac

final class OrbitLegacyIdentityTests: XCTestCase {
    func testLegacyBundledSourceRestoresIdentityAndBuildsCommittedCheckout() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.save()
        func git(_ args: [String]) async throws -> String {
            try await CodeDeviceSupport.git(args, directory: fixture.source.path, root: fixture.root)
        }
        _ = try await git(["init", "-b", "main"])
        try Data("Config/Local.xcconfig\n".utf8).write(to: fixture.source.appendingPathComponent(".gitignore"))
        _ = try await git(["add", "."])
        _ = try await git(["-c", "user.name=Orbit Tests", "-c", "user.email=tests@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "fixture"])
        try Data("uncommitted editor changes".utf8).write(to: fixture.source.appendingPathComponent("Orbit.xcodeproj/project.pbxproj"))
        let before = try await git(["status", "--porcelain"])
        try await fixture.setup.restoreLegacyIdentity(for: fixture.project, phoneBundleID: fixture.bundle)
        let selected = try CodeOrbitIdentity.resolve(fixture.project)
        XCTAssertEqual(selected.bundlePrefix, fixture.state.bundlePrefix)
        XCTAssertEqual(selected.developmentTeam, fixture.state.teamID)
        XCTAssertEqual(selected.iosBundleID, fixture.bundle)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.local.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let checkout = try await CodeDeviceCheckout.create(project: fixture.project, branch: "main", root: fixture.root, name: "legacy")
        XCTAssertEqual(checkout.project.iosBundleID, fixture.bundle)
        XCTAssertEqual(try String(contentsOf: checkout.directory.appendingPathComponent("Orbit.xcodeproj/project.pbxproj"), encoding: .utf8), "committed project")
        let after = try await git(["status", "--porcelain"])
        XCTAssertEqual(before, after)
        await checkout.remove(root: fixture.root)
    }

    func testRecoveryRequiresMatchingSavedSourceAndSigningIdentity() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Missing setup must not create a new random identity.
        try await fixture.setup.restoreLegacyIdentity(for: fixture.project, phoneBundleID: fixture.bundle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.local.path))
        try await fixture.save()
        for key in ["team", "prefix", "bundle", "phone"] {
            var project = fixture.project
            var phone: String? = fixture.bundle
            switch key {
            case "team": project.developmentTeam = "KLMNOPQRST"
            case "prefix": project.bundlePrefix = "dev.test.changed"
            case "bundle": project.iosBundleID = "dev.test.changed"
            default: phone = nil
            }
            do {
                try await fixture.setup.restoreLegacyIdentity(for: project, phoneBundleID: phone)
                XCTFail("Mismatched \(key) must stop recovery")
            } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.local.path))
        }
        var state = fixture.state; state.source = fixture.root.appendingPathComponent("Other").path
        try await fixture.setup.save(state)
        try await fixture.setup.restoreLegacyIdentity(for: fixture.project, phoneBundleID: fixture.bundle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.local.path))
    }

    func testHostBuildChecksLegacyIdentityBeforeSubmittingWork() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.save()
        var config = OrbitConfiguration(); config.phoneBundleID = "dev.test.different"
        try JSONEncoder().encode(config).write(to: fixture.root.appendingPathComponent("config.json"))
        let target = OrbitTarget(name: "Orbit", project: fixture.project, deviceID: "inert-phone")
        try JSONEncoder().encode([target]).write(to: fixture.root.appendingPathComponent("targets.json"))
        let host = try OrbitHost(root: fixture.root)
        let request = try JSONSerialization.data(withJSONObject: ["method": "build", "params": ["id": target.id]])
        let response = try JSONSerialization.jsonObject(with: await host.handle(request)) as? [String: Any]
        XCTAssertTrue((response?["error"] as? String)?.contains("saved signing details don’t match") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.local.path))
    }

    func testRecoveryPreservesExistingConfigAndExactBundle() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.save()
        var project = fixture.project; project.iosBundleID = "dev.test.existing"
        try await fixture.setup.restoreLegacyIdentity(for: project, phoneBundleID: project.iosBundleID)
        XCTAssertEqual(try CodeOrbitIdentity.resolve(project).iosBundleID, project.iosBundleID)
        let original = "user-owned invalid config"
        try Data(original.utf8).write(to: fixture.local)
        try await fixture.setup.restoreLegacyIdentity(for: fixture.project, phoneBundleID: fixture.bundle)
        XCTAssertEqual(try String(contentsOf: fixture.local, encoding: .utf8), original)
    }

    func testRecoveryNeverWritesThroughExternalSourceOrConfigSymlinks() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("DeveloperCheckout")
        try FileManager.default.moveItem(at: fixture.source, to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: outside)
        try await fixture.save()
        try await fixture.setup.restoreLegacyIdentity(for: fixture.project, phoneBundleID: fixture.bundle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Config/Local.xcconfig").path))
        try FileManager.default.removeItem(at: fixture.source)
        try FileManager.default.moveItem(at: outside, to: fixture.source)
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("Config"), to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("Config"), withDestinationURL: outside)
        try await fixture.setup.restoreLegacyIdentity(for: fixture.project, phoneBundleID: fixture.bundle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Local.xcconfig").path))
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var source: URL { root.appendingPathComponent("PhoneSource/old-revision") }
        var local: URL { source.appendingPathComponent("Config/Local.xcconfig") }
        var setup: OrbitSetup { OrbitSetup(root: root) }
        let bundle = "dev.test.orbit.ios"
        var state: OrbitSetupState {
            var state = OrbitSetupState()
            state.source = source.path; state.bundlePrefix = "dev.test.orbit"; state.teamID = "ABCDEFGHIJ"
            return state
        }
        var project: CodeProject {
            var project = CodeProject(path: source.appendingPathComponent("Orbit.xcodeproj").path, scheme: "Orbit")
            project.bundlePrefix = state.bundlePrefix; project.developmentTeam = state.teamID
            return project
        }
        init() throws {
            try FileManager.default.createDirectory(at: source.appendingPathComponent("Config"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("Orbit.xcodeproj"), withIntermediateDirectories: true)
            try Data().write(to: source.appendingPathComponent("Config/Orbit.xcconfig"))
            try Data("committed project".utf8).write(to: source.appendingPathComponent("Orbit.xcodeproj/project.pbxproj"))
        }
        func save() async throws { try await setup.save(state) }
    }
}
