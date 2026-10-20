import XCTest
@testable import OrbitCore
@testable import OrbitMac

final class CodeDeviceSigningTests: XCTestCase {
    func testIgnoredLocalTeamIsPassedAsBuildWideOverride() throws {
        XCTAssertEqual(try CodeDeviceSigning.arguments(checkout: [:], local: ["DEVELOPMENT_TEAM": "LOCALTEAM1"]),
                       ["DEVELOPMENT_TEAM=LOCALTEAM1"])
        XCTAssertEqual(try CodeDeviceSigning.arguments(checkout: ["DEVELOPMENT_TEAM": "  "], local: ["DEVELOPMENT_TEAM": " LOCALTEAM1\n"]),
                       ["DEVELOPMENT_TEAM=LOCALTEAM1"])
    }

    func testCommittedBranchTeamTakesPrecedence() throws {
        XCTAssertEqual(try CodeDeviceSigning.arguments(checkout: ["DEVELOPMENT_TEAM": "BRANCHTEAM"], local: ["DEVELOPMENT_TEAM": "LOCALTEAM1"]), [])
        XCTAssertEqual(try CodeDeviceSigning.arguments(checkout: ["DEVELOPMENT_TEAM": "BRANCHTEAM"], local: nil), [])
    }

    func testMissingTeamReturnsActionableSetupFailure() {
        for local: [String: String]? in [nil, [:], ["DEVELOPMENT_TEAM": " \n"]] {
            XCTAssertThrowsError(try CodeDeviceSigning.arguments(checkout: [:], local: local)) { error in
                XCTAssertTrue(error.localizedDescription.contains("original project on your Mac"))
            }
        }
    }
}
