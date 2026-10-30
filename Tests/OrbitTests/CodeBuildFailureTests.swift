import XCTest
@testable import OrbitMac

final class CodeBuildFailureTests: XCTestCase {
    private let warning = "DVTDeveloperAccountManager: Invalid credentials in keychain for developer@example.test, missing Xcode-Token"
    private let accountError = "/private/checkout/App.xcodeproj: error: No Accounts: Add a new account in Accounts settings."
    private let capabilityError = "/private/checkout/App.xcodeproj: error: Provisioning profile \"iOS Team Provisioning Profile: test.app\" doesn't include the com.apple.developer.usernotifications.time-sensitive entitlement."

    func testAccountAndCapabilityFailuresBothReachSummaryWithoutPrivateDetails() {
        let message = CodeBuildFailure.message(output: [warning, accountError, capabilityError].joined(separator: "\n"))
        XCTAssertTrue(message.contains("Settings → Accounts"))
        XCTAssertTrue(message.contains("Time Sensitive Notifications"))
        XCTAssertTrue(message.contains("Signing & Capabilities"))
        XCTAssertFalse(message.contains("developer@example.test"))
        XCTAssertFalse(message.contains("/private/checkout"))
        XCTAssertFalse(message.contains("test.app"))
    }

    func testAccountFailureWithoutCapabilityAndCapabilityWithoutAccount() {
        let account = CodeBuildFailure.message(output: accountError)
        XCTAssertTrue(account.contains("sign in again"))
        XCTAssertFalse(account.contains("capability"))
        let capability = CodeBuildFailure.message(output: capabilityError)
        XCTAssertTrue(capability.contains("Time Sensitive Notifications"))
        XCTAssertFalse(capability.contains("sign in again"))
        XCTAssertTrue(CodeBuildFailure.message(output: warning + "\n" + capabilityError).contains("sign in again"))
    }

    func testUnrelatedAccountWarningDoesNotHideCompilerFailure() {
        XCTAssertEqual(CodeBuildFailure.message(output: warning + "\nFile.swift:12: error: cannot find name 'missing' in scope"), CodeBuildFailure.fallback)
        XCTAssertEqual(CodeBuildFailure.message(output: "note: Provisioning profile doesn't include a capability"), CodeBuildFailure.fallback)
        XCTAssertEqual(CodeBuildFailure.message(output: ""), CodeBuildFailure.fallback)
    }

    func testOtherCapabilitiesAndAccountErrorVariants() {
        let message = CodeBuildFailure.message(output: "App.xcodeproj: error: Provisioning profile doesn't support the iCloud capability.")
        XCTAssertTrue(message.contains("missing a required capability"))
        XCTAssertFalse(message.contains("Time Sensitive"))
        for error in ["No Account for Team TESTTEAM00", "Your session has expired. Please log in.", "Unable to authenticate with authentication credentials"] {
            XCTAssertTrue(CodeBuildFailure.message(output: "error: " + error).contains("Settings → Accounts"))
        }
    }

    func testBoundedReadIncludesStartupAndTailOfLargeLog() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data((warning + "\n").utf8)
        data.append(Data(repeating: 120, count: 2 * 1024 * 1024))
        data.append(Data(("\n" + capabilityError).utf8))
        try data.write(to: file)
        XCTAssertEqual(CodeBuildFailure.message(log: file), CodeBuildFailure.message(output: warning + "\n" + capabilityError))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(CodeBuildFailure.message(log: file), CodeBuildFailure.fallback)
    }
}
