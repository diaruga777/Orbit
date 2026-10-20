import XCTest
@testable import OrbitCore

final class CodeSessionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() { suite = UUID().uuidString; defaults = UserDefaults(suiteName: suite)! }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testProjectAndLastFileSurviveRelaunchAndStayIsolated() {
        let session = CodeSessionStore(defaults: defaults)
        let first = CodeProject(path: "/Projects/One/App.xcodeproj", scheme: "App", appID: "123", groupID: "group")
        let second = CodeProject(path: "/Projects/Two/App.xcworkspace")
        session.setProject(first, peer: "macA")
        session.setLastFile("/Projects/One/Source.swift", peer: "macA")
        session.setProject(second, peer: "macA")
        XCTAssertNil(session.lastFile(peer: "macA"))
        session.setLastFile("/Projects/Two/Other.swift", peer: "macA")
        let relaunched = CodeSessionStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(relaunched.project(peer: "macA"), second)
        XCTAssertEqual(relaunched.lastFile(peer: "macA"), "/Projects/Two/Other.swift")
        XCTAssertNil(relaunched.project(peer: "macB")); XCTAssertNil(relaunched.lastFile(peer: "macB"))
        relaunched.setProject(first, peer: "macA")
        XCTAssertEqual(relaunched.lastFile(peer: "macA"), "/Projects/One/Source.swift")
        XCTAssertEqual(relaunched.project(peer: "macA"), first)
    }
    func testLegacySelectionMigratesAndCloseDoesNotReopenFile() throws {
        let project = CodeProject(path: "/Projects/One/App.xcodeproj", scheme: "App")
        defaults.set(try JSONEncoder().encode(project), forKey: "Code.project.mac")
        defaults.set("/Projects/One/Source.swift", forKey: "Code.lastFile.mac")
        let session = CodeSessionStore(defaults: defaults)
        XCTAssertEqual(session.project(peer: "mac"), project)
        XCTAssertEqual(session.lastFile(peer: "mac"), "/Projects/One/Source.swift")
        session.setLastFile(nil, peer: "mac")
        XCTAssertNil(CodeSessionStore(defaults: defaults).lastFile(peer: "mac"))
        XCTAssertEqual(session.project(peer: "mac"), project)
    }
    func testLegacyFileFromAnotherProjectIsNotRestored() throws {
        defaults.set(try JSONEncoder().encode(CodeProject(path: "/Projects/One/App.xcodeproj")), forKey: "Code.project.mac")
        defaults.set("/Projects/OneOther/Source.swift", forKey: "Code.lastFile.mac")
        XCTAssertNil(CodeSessionStore(defaults: defaults).lastFile(peer: "mac"))
    }
}
