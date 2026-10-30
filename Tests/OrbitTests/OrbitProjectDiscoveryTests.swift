import XCTest
@testable import OrbitHost

final class OrbitProjectDiscoveryTests: XCTestCase {
    func testSchemeInspectionRequiresTrustBeforeInvokingXcode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let data = await host.handle(Data(#"{"method":"project_apps","params":{"project":"/unused/App.xcodeproj"}}"#.utf8))
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue((result?["error"] as? String ?? "").contains("trust"))
        let download = await host.handle(Data(#"{"method":"repo_prepare","params":{"repository":"demo/App"}}"#.utf8))
        XCTAssertTrue(((try JSONSerialization.jsonObject(with: download) as? [String: Any])?["error"] as? String ?? "").contains("trust"))
        let denied = await host.handle(Data(#"{"method":"projects_detect"}"#.utf8), peer: "unknown")
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: denied) as? [String: Any])?["error"])
    }
    func testScanFindsContainersWithoutDescendingIntoProjectsCachesOrSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        for path in ["App/Main.xcodeproj/project.xcworkspace", "App/Main.xcworkspace", "Pods/Dependency.xcodeproj", ".hidden/Hidden.xcodeproj", "Library/Cache.xcodeproj", "Other/Second.xcodeproj"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: root.appendingPathComponent("Other"))
        let paths = OrbitProjectDiscovery.scan(roots: [root, root])
        XCTAssertEqual(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, ["App/Main.xcodeproj", "App/Main.xcworkspace", "Other/Second.xcodeproj"].map { root.appendingPathComponent($0).resolvingSymlinksInPath().path }.sorted())
        XCTAssertEqual(OrbitProjectDiscovery.scan(roots: [root], limit: 1).count, 1)
        XCTAssertTrue(OrbitProjectDiscovery.scan(roots: [root], maximumEntries: 0).isEmpty)
    }
}
