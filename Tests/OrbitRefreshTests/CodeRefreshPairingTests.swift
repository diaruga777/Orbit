import XCTest
import IdeviceGateway

final class CodeRefreshPairingTests: XCTestCase {
    func testModernAndHybridPairingRecordsValidateWithoutOpeningDeviceConnection() throws {
        var plist: [String: Any] = ["private_key": Data(repeating: 1, count: 32), "public_key": Data(repeating: 2, count: 32), "identifier": UUID().uuidString]
        func text(_ value: [String: Any]) throws -> String { String(decoding: try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0), as: UTF8.self) }
        XCTAssertNoThrow(try IdeviceGateway.validatePairingForRefresh(text(plist)))
        plist["HostID"] = "legacy"
        XCTAssertNoThrow(try IdeviceGateway.validatePairingForRefresh(text(plist)))
        plist.removeValue(forKey: "private_key")
        XCTAssertThrowsError(try IdeviceGateway.validatePairingForRefresh(text(plist)))
    }
}
