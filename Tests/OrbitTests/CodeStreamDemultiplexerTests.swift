import XCTest
import Darwin
import OrbitCore
import OrbitWire
import OrbitTransport

final class CodeStreamDemultiplexerTests: XCTestCase {
    private func pair() throws -> (FileDescriptorByteStream, FileDescriptorByteStream) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw BEPStreamError.posix(errno) }
        return (FileDescriptorByteStream(fileDescriptor: descriptors[0]), FileDescriptorByteStream(fileDescriptor: descriptors[1]))
    }
    func testOrbitControlMagicIsReplayedWithoutModification() async throws {
        let pair = try pair(); defer { pair.0.close(); pair.1.close() }
        let bytes = Data("ORBThello".utf8)
        try await pair.1.write(bytes)
        let routed = try await OrbitStreamDemultiplexer.classify(pair.0)
        XCTAssertFalse(routed.installation)
        let replayed = try await routed.stream.read(exactly: bytes.count)
        XCTAssertEqual(replayed, bytes)
    }

    func testDedicatedAppleFrameMagicAndPayloadAreReplayed() async throws {
        let pair = try pair(); defer { pair.0.close(); pair.1.close() }
        let payload = Data("fixture-proof".utf8)
        let bytes = try CodeInstallFrame(.reverseProof, payload: payload).encoded()
        try await pair.1.write(Data(bytes.prefix(2))); try await pair.1.write(Data(bytes.dropFirst(2)))
        let routed = try await OrbitStreamDemultiplexer.classify(pair.0)
        XCTAssertTrue(routed.installation)
        let frame = try await CodeInstallFrame.read(from: OrbitInstallStream(authenticatedStream: routed.stream))
        XCTAssertEqual(frame.kind, .reverseProof); XCTAssertEqual(frame.payload, payload)
    }
    func testCancellationClosesAStalledClassification() async throws {
        let pair = try pair(); defer { pair.0.close(); pair.1.close() }
        let pending = Task { try await OrbitStreamDemultiplexer.classify(pair.0) }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("cancelled classification survived") } catch {}
    }
}
