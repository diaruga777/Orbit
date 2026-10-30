import XCTest
@testable import OrbitRefresh

final class CodeRefreshSignInTests: XCTestCase {
    func testEmptyServerUsesDefaultAndCredentialsAreValidatedBeforeNetworking() throws {
        for blank in ["", " \n\t"] {
            let input = try CodeRefreshSignInInput(appleID: " me@example.test \n", password: " password ", server: blank, rememberPassword: true)
            XCTAssertEqual(input.server.absoluteString, "https://ani.sidestore.io")
            XCTAssertEqual(input.appleID, "me@example.test")
            XCTAssertEqual(input.password, " password ") // Password whitespace is significant.
            XCTAssertTrue(input.rememberPassword)
        }
        XCTAssertThrowsError(try CodeRefreshSignInInput(appleID: " \n", password: "password", server: "", rememberPassword: false))
        XCTAssertThrowsError(try CodeRefreshSignInInput(appleID: "me@example.test", password: "", server: "", rememberPassword: false))
    }
    func testCustomServerRequiresAnUnambiguousHTTPSAddress() throws {
        let custom = try CodeRefreshSignInInput.serverURL(" https://helper.example.test:8443/anisette/ \n")
        XCTAssertEqual(custom.absoluteString, "https://helper.example.test:8443/anisette/")
        for invalid in ["helper.example.test", "http://helper.example.test", "https://", "file:///tmp/helper", "https://helper.example.test/a b", "https://user:password@helper.example.test", "https://helper.example.test?token=secret", "https://helper.example.test#fragment"] {
            XCTAssertThrowsError(try CodeRefreshSignInInput.serverURL(invalid), invalid)
        }
    }
}
