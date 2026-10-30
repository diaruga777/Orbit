import XCTest
import OrbitCore
@testable import OrbitMac

final class CodeOrbitIdentityTests: XCTestCase {
    func testLocalIdentityWinsOverStaleCatalogWithoutChangingOtherApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Config"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Config/Orbit.xcconfig"))
        let local = root.appendingPathComponent("Config/Local.xcconfig")
        var project = CodeProject(path: root.appendingPathComponent("Orbit.xcodeproj").path, scheme: "Orbit")
        project.developmentTeam = "STALETEAM1"; project.bundlePrefix = "old.sample.app"
        XCTAssertThrowsError(try CodeOrbitIdentity.resolve(project))
        try Data("ORBIT_BUNDLE_PREFIX = dev.test.orbit\nDEVELOPMENT_TEAM = ABCDEFGHIJ\nORBIT_IOS_BUNDLE_IDENTIFIER = dev.test.existing\n".utf8).write(to: local)
        let selected = try CodeOrbitIdentity.resolve(project)
        XCTAssertEqual(selected.developmentTeam, "ABCDEFGHIJ")
        XCTAssertEqual(selected.bundlePrefix, "dev.test.orbit")
        XCTAssertEqual(selected.iosBundleID, "dev.test.existing")
        XCTAssertTrue(selected.xcodeArguments.contains("ORBIT_IOS_BUNDLE_IDENTIFIER=dev.test.existing"))
        XCTAssertNoThrow(try CodeOrbitIdentity.verify(bundleID: "dev.test.existing", project: selected))
        XCTAssertThrowsError(try CodeOrbitIdentity.verify(bundleID: "dev.test.orbit.ios", project: selected))
        project.path = root.appendingPathComponent("Other.xcodeproj").path
        XCTAssertEqual(try CodeOrbitIdentity.resolve(project), project)
        XCTAssertEqual(try JSONDecoder().decode(CodeProject.self, from: JSONEncoder().encode(selected)), selected)
    }
    func testDetachedSelfBuildStagesOnlyIdentityAndPreservesSourceCheckout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("Repo"), state = root.appendingPathComponent("State")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Config"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Orbit.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        func git(_ args: [String]) async throws -> String { try await CodeDeviceSupport.git(args, directory: repo.path, root: state) }
        _ = try await git(["init", "-b", "main"])
        _ = try await git(["config", "user.name", "Orbit Tests"])
        _ = try await git(["config", "user.email", "orbit@example.invalid"])
        try Data("Config/Local.xcconfig\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        try Data("committed configuration".utf8).write(to: repo.appendingPathComponent("Config/Orbit.xcconfig"))
        try Data("committed project".utf8).write(to: repo.appendingPathComponent("Orbit.xcodeproj/project.pbxproj"))
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "fixture"])
        let config = "ORBIT_BUNDLE_PREFIX = dev.test.orbit\nDEVELOPMENT_TEAM = ABCDEFGHIJ\nORBIT_IOS_BUNDLE_IDENTIFIER = dev.test.existing\nPRIVATE_UNRELATED_SETTING = do-not-copy\n"
        try Data(config.utf8).write(to: repo.appendingPathComponent("Config/Local.xcconfig"))
        try Data("unsaved project".utf8).write(to: repo.appendingPathComponent("Orbit.xcodeproj/project.pbxproj"))
        let before = try await git(["status", "--porcelain"])
        let checkout = try await CodeDeviceCheckout.create(project: CodeProject(path: repo.appendingPathComponent("Orbit.xcodeproj").path, scheme: "Orbit"), branch: "main", root: state, name: "identity")
        let staged = try String(contentsOf: checkout.directory.appendingPathComponent("Config/Local.xcconfig"), encoding: .utf8)
        XCTAssertTrue(staged.contains("ORBIT_IOS_BUNDLE_IDENTIFIER = dev.test.existing"))
        XCTAssertFalse(staged.contains("PRIVATE_UNRELATED_SETTING"))
        XCTAssertEqual(try String(contentsOf: checkout.directory.appendingPathComponent("Orbit.xcodeproj/project.pbxproj"), encoding: .utf8), "committed project")
        let branch = try await CodeDeviceSupport.git(["branch", "--show-current"], directory: checkout.directory.path, root: state)
        XCTAssertEqual(branch, "")
        let after = try await git(["status", "--porcelain"])
        XCTAssertEqual(before, after)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("Config/Local.xcconfig"), encoding: .utf8), config)
        await checkout.remove(root: state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.directory.path))
    }
    func testSampleMissingAndExecutableConfigValuesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Config"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Config/Orbit.xcconfig"))
        let project = CodeProject(path: root.appendingPathComponent("Orbit.xcodeproj").path, scheme: "Orbit")
        for value in ["ORBIT_BUNDLE_PREFIX = org.example.orbit\nDEVELOPMENT_TEAM = ABCDEFGHIJ", "ORBIT_BUNDLE_PREFIX = dev.test.orbit", "ORBIT_BUNDLE_PREFIX = $(OTHER)\nDEVELOPMENT_TEAM = ABCDEFGHIJ", "ORBIT_BUNDLE_PREFIX = dev.test.orbit\nDEVELOPMENT_TEAM = ABCDEFGHIJ\nORBIT_IOS_BUNDLE_IDENTIFIER = com.yourname.orbit"] {
            try Data(value.utf8).write(to: root.appendingPathComponent("Config/Local.xcconfig"))
            XCTAssertThrowsError(try CodeOrbitIdentity.resolve(project))
        }
        try Data("ORBIT_BUNDLE_PREFIX = dev.test.orbit\nDEVELOPMENT_TEAM = ABCDEFGHIJ\n".utf8).write(to: root.appendingPathComponent("Config/Local.xcconfig"))
        XCTAssertEqual(try CodeOrbitIdentity.resolve(project).iosBundleID, "dev.test.orbit.ios")
    }
}
