import XCTest
import SideSign
@testable import OrbitRefresh

final class CodeRefreshIPATests: XCTestCase {
    func testRejectsTraversalBeforeWritingAnyFile() throws {
        try withArchive(paths: ["Payload/App.app/Info.plist", "../outside"]) { ipa, root in
            XCTAssertThrowsError(try CodeRefreshIPA.extract(ipa, to: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Payload").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("outside").path))
        }
    }
    func testExtractsOneAppAndPreservesExecutablePermission() throws {
        try withArchive(paths: ["Payload/App.app/Info.plist", "Payload/App.app/App"]) { ipa, root in
            let app = try CodeRefreshIPA.extract(ipa, to: root)
            XCTAssertEqual(app.lastPathComponent, "App.app")
            XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("App"), encoding: .utf8), "fixture")
            let permissions = try FileManager.default.attributesOfItem(atPath: app.appendingPathComponent("App").path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o755)
        }
    }
    func testRejectsMultiplePayloadApps() throws {
        try withArchive(paths: ["Payload/A.app/Info.plist", "Payload/B.app/Info.plist"]) { ipa, root in
            XCTAssertThrowsError(try CodeRefreshIPA.extract(ipa, to: root))
        }
    }
    private func withArchive(paths: [String], body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ipa = directory.appendingPathComponent("Fixture.ipa"), root = directory.appendingPathComponent("Extracted")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = try Archive.Writer.create(at: ipa)
        for path in paths { try writer.writeFile(path: path, data: Data("fixture".utf8), permissions: 0o100755) }
        try writer.close()
        try body(ipa, root)
    }
}
