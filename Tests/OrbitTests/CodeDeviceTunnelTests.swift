import XCTest
import CryptoKit
@testable import OrbitCore

final class CodeDeviceTunnelTests: XCTestCase {
    func testFrameRoundTripAndBounds() async throws {
        let pair = TunnelTestStream.pair()
        let payload = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0) })
        let encoded = try CodeInstallFrame(.data, payload: payload).encoded()
        // Deliberately fragment the header and payload at unrelated boundaries.
        for index in stride(from: 0, to: encoded.count, by: 17) { try await pair.0.write(encoded.subdata(in: index..<min(encoded.count, index + 17))) }
        let decoded = try await CodeInstallFrame.read(from: pair.1)
        XCTAssertEqual(decoded, CodeInstallFrame(.data, payload: payload))
        XCTAssertThrowsError(try CodeInstallFrame(.data, payload: Data(count: 65537)).encoded())
        try await pair.0.write(Data([0x4c, 0x43, 0x44, 0x46, 1, 2, 0xff, 0xff, 0xff, 0xff]))
        do { _ = try await CodeInstallFrame.read(from: pair.1); XCTFail("Oversize header cannot allocate its payload") } catch {}
        pair.0.close(); pair.1.close()
    }
    func testLeaseRejectsReplayWrongTargetWrongPeerAndExpiration() async throws {
        let clock = TunnelTestClock(), closed = TunnelTestCounter()
        let authority = CodeDeviceFlowAuthority(uptime: { clock.now })
        let open = try await authority.issue(peerID: "mac", verifiedDeviceID: "phone", verifiedEndpointIDs: ["apple-service"], generation: "g", seconds: 1)
        _ = try await authority.acquire(open, peerID: "mac", close: { closed.increment() })
        try await authority.renew(open, peerID: "mac", sequence: 1, seconds: 2)
        do { try await authority.renew(open, peerID: "mac", sequence: 1, seconds: 2); XCTFail("Replay") } catch {}
        var wrong = open; wrong.targetDeviceID = "other"
        do { try await authority.consume(1, open: wrong, peerID: "mac"); XCTFail("Wrong physical phone") } catch {}
        wrong = open; wrong.generation = "old"
        do { try await authority.consume(1, open: wrong, peerID: "mac"); XCTFail("Old generation") } catch {}
        do { try await authority.consume(1, open: open, peerID: "revoked"); XCTFail("Wrong peer") } catch {}
        clock.now = 3
        do { try await authority.consume(1, open: open, peerID: "mac"); XCTFail("Expired") } catch {}
        XCTAssertEqual(closed.value, 1)
    }
    func testUnauthorizedProxyNeverOpensDeviceSocket() async throws {
        let authority = CodeDeviceFlowAuthority(), opened = TunnelTestCounter()
        var open = try await authority.issue(peerID: "mac", verifiedDeviceID: "phone", verifiedEndpointIDs: ["service"], generation: "g")
        open.endpointID = "unlisted-service"
        let pair = TunnelTestStream.pair()
        try await pair.0.write(CodeInstallFrame(.open, payload: JSONEncoder().encode(open)).encoded())
        do {
            try await CodeDeviceFlowProxy.serve(stream: pair.1, authenticatedPeerID: "mac", authority: authority) { _ in opened.increment(); return TunnelTestEchoSocket() }
            XCTFail("Unauthorized endpoint")
        } catch {}
        XCTAssertEqual(opened.value, 0)
    }
    func testProxyForwardsOpaqueBytesAndPreservesHalfClose() async throws {
        let authority = CodeDeviceFlowAuthority()
        let open = try await authority.issue(peerID: "mac", verifiedDeviceID: "phone", verifiedEndpointIDs: ["service"], generation: "g")
        let pair = TunnelTestStream.pair(), socket = TunnelTestEchoSocket()
        let serving = Task { try await CodeDeviceFlowProxy.serve(stream: pair.1, authenticatedPeerID: "mac", authority: authority) { _ in socket } }
        try await pair.0.write(CodeInstallFrame(.open, payload: JSONEncoder().encode(open)).encoded())
        let accepted = try await CodeInstallFrame.read(from: pair.0); XCTAssertEqual(accepted.kind, .accepted)
        let opaque = Data([0, 255, 1, 13, 10, 0, 128])
        try await pair.0.write(CodeInstallFrame(.data, payload: opaque).encoded())
        let echo = try await CodeInstallFrame.read(from: pair.0); XCTAssertEqual(echo.payload, opaque)
        try await pair.0.write(CodeInstallFrame(.halfClose).encoded())
        let end = try await CodeInstallFrame.read(from: pair.0); XCTAssertEqual(end.kind, .halfClose)
        try await serving.value
    }
    func testRevocationClosesBlockedFlow() async throws {
        let authority = CodeDeviceFlowAuthority()
        let open = try await authority.issue(peerID: "mac", verifiedDeviceID: "phone", verifiedEndpointIDs: ["service"], generation: "g")
        let pair = TunnelTestStream.pair()
        let serving = Task { try await CodeDeviceFlowProxy.serve(stream: pair.1, authenticatedPeerID: "mac", authority: authority) { _ in TunnelTestEchoSocket() } }
        try await pair.0.write(CodeInstallFrame(.open, payload: JSONEncoder().encode(open)).encoded())
        _ = try await CodeInstallFrame.read(from: pair.0)
        await authority.revoke(peerID: "mac")
        do { try await serving.value; XCTFail("Revoked flow must stop") } catch {}
    }
    func testEndpointProofHasDomainSeparationAndRejectsWrongKey() throws {
        let key = P256.Signing.PrivateKey(), other = P256.Signing.PrivateKey(), challenge = Data(repeating: 7, count: 32)
        let signature = try key.signature(for: Data("orbit-install-endpoint-v1\u{0}".utf8) + challenge).derRepresentation
        XCTAssertTrue(CodeInstallEndpointIdentity.verify(signature: signature, challenge: challenge, publicKey: key.publicKey.x963Representation))
        XCTAssertFalse(CodeInstallEndpointIdentity.verify(signature: signature, challenge: challenge, publicKey: other.publicKey.x963Representation))
        XCTAssertFalse(CodeInstallEndpointIdentity.verify(signature: signature, challenge: Data(repeating: 8, count: 32), publicKey: key.publicKey.x963Representation))
    }
}
private final class TunnelTestClock: @unchecked Sendable { var now: TimeInterval = 0 }
private final class TunnelTestCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
private actor TunnelTestBuffer {
    var data = Data(), ended = false
    func append(_ bytes: Data) throws { guard !ended else { throw CodeFailure("closed") }; data.append(bytes) }
    func end() { ended = true }
    func read(_ size: Int, partial: Bool = false) async throws -> Data? {
        if size == 0 { return Data() }
        while (partial ? data.isEmpty : data.count < size) && !ended { try await Task.sleep(for: .milliseconds(1)) }
        if data.isEmpty && ended { return nil }
        guard partial || data.count >= size else { throw CodeFailure("incomplete") }
        let bytes = Data(data.prefix(min(size, data.count))); data.removeFirst(bytes.count); return bytes
    }
}
private final class TunnelTestStream: CodeInstallStream, @unchecked Sendable {
    let input: TunnelTestBuffer, output: TunnelTestBuffer
    init(_ input: TunnelTestBuffer, _ output: TunnelTestBuffer) { self.input = input; self.output = output }
    static func pair() -> (TunnelTestStream, TunnelTestStream) {
        let a = TunnelTestBuffer(), b = TunnelTestBuffer(); return (TunnelTestStream(a, b), TunnelTestStream(b, a))
    }
    func read(exactly count: Int) async throws -> Data { guard let data = try await input.read(count) else { throw CodeFailure("closed") }; return data }
    func write(_ data: Data) async throws { try await output.append(data) }
    func close() { Task { await input.end(); await output.end() } }
}
private final class TunnelTestEchoSocket: CodeDeviceFlowSocket, @unchecked Sendable {
    let buffer = TunnelTestBuffer()
    func read(maximum: Int) async throws -> Data? { try await buffer.read(maximum, partial: true) }
    func write(_ data: Data) async throws { try await buffer.append(data) }
    func halfClose() async throws { await buffer.end() }
    func close() { Task { await buffer.end() } }
}
