import XCTest
@testable import OrbitCore

final class OrbitPageCacheTests: XCTestCase {
    func testSuccessfulEmptySnapshotSurvivesRecreationAndIsPeerScoped() throws {
        let suite = "OrbitPageCacheTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = OrbitPageCache(key: "apps", defaults: defaults)
        XCTAssertNil(cache.load(peer: "mac-a"))
        cache.save(Data("[]".utf8), peer: "mac-a")
        XCTAssertEqual(OrbitPageCache(key: "apps", defaults: defaults).load(peer: "mac-a"), Data("[]".utf8))
        XCTAssertNil(cache.load(peer: "mac-b"))
        XCTAssertNil(cache.load(peer: "unpaired"))
        cache.save(Data("bad".utf8), peer: "unpaired")
        XCTAssertEqual(cache.load(peer: "mac-a"), Data("[]".utf8))
        defaults.set("corrupt", forKey: "apps")
        XCTAssertNil(cache.load(peer: "mac-a"))
    }
}
