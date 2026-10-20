import XCTest
import OrbitCore
import OrbitMac

final class CodePermissionTests: XCTestCase {
    func testPermissionPreflightReturnsActionableServiceErrorBeforeFileAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try CodeService(root: root, checkAccess: { _ in throw CodeFailure("Allow folder access on your Mac, then retry.") })
        let client = CodeClient { await service.handle($0) }
        do { _ = try await client.call(CodeRequest(.open, path: "/protected/source.swift")); XCTFail("Expected permission error") }
        catch { XCTAssertEqual(error.localizedDescription, "Allow folder access on your Mac, then retry.") }
        // Status/cancel requests must still work while another request waits on access.
        var status = CodeRequest(.job); status.jobID = "missing"
        do { _ = try await client.call(status); XCTFail("Expected missing job") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer available")) }
    }
}
