import XCTest
@testable import OrbitMac

final class CodeXcodeToolsTests: XCTestCase {
    func testStandaloneOrRemovedSelectionFallsBackToInstalledXcode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Renamed Xcode Beta.app")
        let directory = try fixture(app)
        for selected in ["/Library/Developer/CommandLineTools", root.appendingPathComponent("Removed.app/Contents/Developer").path, ""] {
            XCTAssertEqual(try CodeXcodeTools.resolve(explicit: nil, selected: selected, applications: [root.appendingPathComponent("Incomplete.app"), app]), directory)
        }
    }
    func testExplicitAndSystemSelectionsTakePrecedenceAndInvalidOverrideFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try fixture(root.appendingPathComponent("Selected.app"))
        let override = root.appendingPathComponent("Override.app")
        let explicit = try fixture(override)
        XCTAssertEqual(try CodeXcodeTools.resolve(explicit: nil, selected: selected, applications: [override]), selected)
        for path in [override.path, explicit] {
            XCTAssertEqual(try CodeXcodeTools.resolve(explicit: path, selected: selected, applications: []), explicit)
        }
        XCTAssertThrowsError(try CodeXcodeTools.resolve(explicit: "/missing.app", selected: selected, applications: [override]))
        XCTAssertThrowsError(try CodeXcodeTools.resolve(explicit: nil, selected: "/Library/Developer/CommandLineTools", applications: []))
    }
    func testNonAppleCommandsKeepTheirEnvironmentAndDiscoveryRetainsToolError() throws {
        let environment = ["DEVELOPER_DIR": "/missing.app", "PATH": "/fixture", "FIXTURE": "preserved"]
        XCTAssertEqual(try CodeXcodeTools.environment(for: "/usr/bin/git", inheriting: environment), environment)
        XCTAssertThrowsError(try CodeDeviceSupport.checkDeviceDiscoveryStatus(1, output: Data("xcdevice setup failed".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("xcdevice setup failed"))
        }
        XCTAssertNoThrow(try CodeDeviceSupport.checkDeviceDiscoveryStatus(0, output: Data()))
    }
    private func fixture(_ app: URL) throws -> String {
        let directory = app.appendingPathComponent("Contents/Developer")
        let bin = directory.appendingPathComponent("usr/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("xcodebuild")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return directory.path
    }
}
