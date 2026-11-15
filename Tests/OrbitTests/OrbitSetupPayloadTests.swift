import XCTest
@testable import OrbitHost

final class OrbitSetupPayloadTests: XCTestCase {
    func testBundledPayloadCreatesACompleteCommittedPhoneProjectAndResumes() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_TEST_SETUP_BUNDLE"], let bundle = Bundle(path: path) else {
            throw XCTSkip("Supply the packaged review app through ORBIT_TEST_SETUP_BUNDLE.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-payload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = OrbitSetup(root: root)
        let source = try await setup.prepareSource(bundle: bundle)
        let files = String(decoding: try await OrbitCommand.run("/usr/bin/git", ["ls-files"], directory: source), as: UTF8.self)
        XCTAssertTrue(files.contains("Vendor/OrbitNet.xcframework/Info.plist"))
        XCTAssertTrue(files.contains("Vendor/DeviceGateway/IDevice.xcframework/Info.plist"))
        XCTAssertTrue(files.contains("Vendor/IrohDirect/Iroh.xcframework/Info.plist"))
        XCTAssertTrue(files.contains("Apps/OrbitWidgets/OrbitWidget.swift"))
        XCTAssertTrue(files.contains("Apps/OrbitShare/OrbitShareController.swift"))
        XCTAssertTrue(files.contains("Apps/OrbitShare/OrbitShare.entitlements"))
        XCTAssertTrue(files.contains("Tests/OrbitWidgetTests/OrbitWidgetTests.swift"))
        XCTAssertFalse(files.contains("Config/Local.xcconfig"))
        let description = try await OrbitCommand.run("/usr/bin/swift", ["package", "describe", "--type", "json"], directory: source)
        let package = try JSONSerialization.jsonObject(with: description) as? [String: Any]
        let targets = (package?["targets"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(targets.contains("OrbitRefresh")); XCTAssertTrue(targets.contains("OrbitWidgets"))
        let resumed = try await setup.prepareSource(bundle: bundle)
        XCTAssertEqual(resumed.standardizedFileURL.path, source.standardizedFileURL.path)
        let revision = try await OrbitCommand.run("/usr/bin/git", ["rev-parse", "HEAD"], directory: source)
        try FileManager.default.removeItem(at: source.appendingPathComponent(".orbit-source-ready"))
        _ = try await setup.prepareSource(bundle: bundle)
        let recovered = try await OrbitCommand.run("/usr/bin/git", ["rev-parse", "HEAD"], directory: source)
        XCTAssertEqual(recovered, revision)
        let changes = try await OrbitCommand.run("/usr/bin/git", ["status", "--porcelain", "--untracked-files=no"], directory: source)
        XCTAssertTrue(changes.isEmpty)
    }
}
