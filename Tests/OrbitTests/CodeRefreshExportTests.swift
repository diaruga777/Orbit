import XCTest
import CryptoKit
import Security
import OrbitCore
import OrbitHost
@testable import OrbitMac

final class CodeRefreshExportTests: XCTestCase {
    func testRetainedBuildExportsBoundedChunksWithStableDigestAndPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeArtifactStore(root: root.appendingPathComponent("Artifacts"))
        let id = UUID().uuidString, app = try store.appURL(id)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var fixture = Data(count: 700_000)
        XCTAssertEqual(fixture.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }, errSecSuccess)
        try fixture.write(to: app.appendingPathComponent("App"))
        let (digest, bytes) = try CodeArtifactStore.digest(app)
        let target = CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: CodeProject(path: "/repo/App.xcodeproj"), branch: "main", generation: "g")
        let artifact = CodeBuildArtifact(id: id, jobID: "job", target: target, bundleID: "test.app", version: "1", build: "1", commit: "c", digest: digest, signingAuthority: "test", byteCount: bytes)
        let exporter = CodeRefreshExport()
        var archive = Data(), offset = 0, expected: CodeRefreshArchiveChunk?
        repeat {
            let chunk = try await exporter.chunk(artifact: artifact, artifacts: store.root, root: root.appendingPathComponent("Exports"), offset: offset)
            XCTAssertLessThanOrEqual(chunk.bytes.count, 256 * 1024)
            XCTAssertEqual(chunk.offset, offset)
            if let expected { XCTAssertEqual(chunk.digest, expected.digest); XCTAssertEqual(chunk.byteCount, expected.byteCount) }
            else { expected = chunk }
            archive.append(chunk.bytes); offset += chunk.bytes.count
        } while offset < expected!.byteCount
        XCTAssertGreaterThan(archive.count, 256 * 1024)
        XCTAssertEqual(SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(), expected?.digest)
        let ipa = root.appendingPathComponent("Downloaded.ipa"); try archive.write(to: ipa)
        let listing = try await OrbitCommand.run("/usr/bin/unzip", ["-l", ipa.path])
        XCTAssertTrue(String(decoding: listing, as: UTF8.self).contains("Payload/App.app/App"))
        do { _ = try await exporter.chunk(artifact: artifact, artifacts: store.root, root: root, offset: archive.count + 1); XCTFail("Invalid offset accepted") } catch { }
    }
    func testTamperedRetainedBuildCannotBeExported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeArtifactStore(root: root.appendingPathComponent("Artifacts"))
        let id = UUID().uuidString, app = try store.appURL(id)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("changed".utf8).write(to: app.appendingPathComponent("App"))
        let target = CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: CodeProject(path: "/repo/App.xcodeproj"), branch: "main", generation: "g")
        let artifact = CodeBuildArtifact(id: id, jobID: "job", target: target, bundleID: "test.app", version: "1", build: "1", commit: "c", digest: "old", signingAuthority: "test", byteCount: 7)
        do { _ = try await CodeRefreshExport().chunk(artifact: artifact, artifacts: store.root, root: root, offset: 0); XCTFail("Tampered build exported") } catch { }
    }
}
