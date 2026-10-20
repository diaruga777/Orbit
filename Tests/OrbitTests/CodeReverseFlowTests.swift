import XCTest
import CryptoKit
import Darwin
@testable import OrbitCore
@testable import OrbitMac

final class CodeReverseFlowTests: XCTestCase {
    private func fixture(clock: ReverseClock = ReverseClock()) -> (CodeReverseFlowHub, P256.Signing.PrivateKey, CodeEndpointBinding) {
        let key = P256.Signing.PrivateKey()
        let binding = CodeEndpointBinding(id: UUID().uuidString, accountPeerID: "account", deviceID: "physical-A", publicKey: key.publicKey.x963Representation)
        let hub = CodeReverseFlowHub(lookup: { id, peer in
            guard id == binding.id, peer == binding.accountPeerID else { throw CodeFailure("revoked") }; return binding
        }, uptime: { clock.now })
        return (hub, key, binding)
    }
    private func sign(_ data: Data, key: P256.Signing.PrivateKey) throws -> Data {
        try key.signature(for: Data("orbit-install-endpoint-v1\u{0}".utf8) + data).derRepresentation
    }
    private func ready(_ hub: CodeReverseFlowHub, key: P256.Signing.PrivateKey, binding: CodeEndpointBinding, generation: String = "g") async throws -> CodeReverseReadiness {
        var control = CodeReverseControl(); control.bindingID = binding.id; control.generation = generation
        let bytes = try await hub.begin(control, peer: "account")
        control.sessionID = try JSONDecoder().decode(CodeReverseChallenge.self, from: bytes).id; control.signature = try sign(bytes, key: key)
        return try await hub.finish(control, peer: "account")
    }
    private func demand(_ hub: CodeReverseFlowHub, ready: CodeReverseReadiness) async throws -> CodeReverseFlowDemand {
        var control = CodeReverseControl(); control.sessionID = ready.id; control.token = ready.token; control.generation = ready.generation
        for i in 1...100 {
            control.sequence = UInt64(i)
            if let flow = try await hub.poll(control, peer: "account").first { return flow }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CodeFailure("No demand")
    }
    func testFreshPhysicalKeyProofForwardsOpaqueBytesWithHalfCloseAndRejectsReplay() async throws {
        let (hub, key, binding) = fixture(); let ready = try await ready(hub, key: key, binding: binding)
        let pending = Task { try await hub.open(readiness: ready, service: .afc, port: 32100) }
        let demand = try await demand(hub, ready: ready)
        let (mac, phone) = ReverseTestStream.pair(); let echo = ReverseEchoSocket()
        let serving = Task {
            try await CodeReversePhoneFlow.serve(demand: demand, readiness: ready, accountPeerID: "account", macPeerID: "mac",
                identityKey: key.publicKey.x963Representation, sign: { try self.sign($0, key: key) }, stream: phone,
                available: {}, openEndpoint: { service, port in XCTAssertEqual(service, .afc); XCTAssertEqual(port, 32100); return echo })
        }
        let first = try await CodeInstallFrame.read(from: mac)
        XCTAssertEqual(first.kind, .reverseProof)
        let proof = try JSONDecoder().decode(CodeReverseStreamProof.self, from: first.payload)
        try await hub.accept(proof, stream: mac, peer: "account")
        let socket = try await pending.value
        let payload = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0) })
        try await socket.write(payload)
        var output = Data()
        while output.count < payload.count { output.append(try await socket.read(maximum: 257) ?? Data()) }
        XCTAssertEqual(output, payload)
        try await socket.halfClose(); let end = try await socket.read(maximum: 10); XCTAssertNil(end)
        try await serving.value; socket.close()
        let replay = ReverseTestStream.pair()
        do { try await hub.accept(proof, stream: replay.0, peer: "account"); XCTFail("replayed physical proof") } catch {}
        replay.0.close(); replay.1.close()
    }
    func testDifferentPhoneKeyCannotOpenAppleSocketEvenWithSharedAccount() async throws {
        let (hub, key, binding) = fixture(); let ready = try await ready(hub, key: key, binding: binding)
        let pending = Task { try await hub.open(readiness: ready, service: .installation, port: 32101) }
        let demand = try await demand(hub, ready: ready); let other = P256.Signing.PrivateKey()
        let pair = ReverseTestStream.pair()
        let proof = CodeReverseStreamProof(flowID: demand.id, sessionID: ready.id, signature: try sign(demand.challenge, key: other))
        do { try await hub.accept(proof, stream: pair.0, peer: "account"); XCTFail("accepted another physical key") } catch {}
        do { _ = try await pending.value; XCTFail("opened flow") } catch {}
        pair.0.close(); pair.1.close()
    }
    func testReadinessRejectsWrongAccountSignatureRenewalReplayAndMonotonicExpiry() async throws {
        let clock = ReverseClock(); let (hub, key, binding) = fixture(clock: clock)
        var control = CodeReverseControl(); control.bindingID = binding.id; control.generation = "g"
        do { _ = try await hub.begin(control, peer: "another-account"); XCTFail("wrong account") } catch {}
        let bytes = try await hub.begin(control, peer: "account")
        control.sessionID = try JSONDecoder().decode(CodeReverseChallenge.self, from: bytes).id
        control.signature = try sign(bytes, key: P256.Signing.PrivateKey())
        do { _ = try await hub.finish(control, peer: "account"); XCTFail("wrong key") } catch {}
        clock.now = 31
        control.signature = try sign(bytes, key: key)
        do { _ = try await hub.finish(control, peer: "account"); XCTFail("expired readiness challenge") } catch {}
        let ready = try await ready(hub, key: key, binding: binding)
        control.sessionID = ready.id; control.generation = ready.generation; control.token = ready.token; control.sequence = 1
        _ = try await hub.poll(control, peer: "account")
        do { _ = try await hub.poll(control, peer: "account"); XCTFail("renewal replay") } catch {}
        clock.now = 92
        do { _ = try await hub.readiness(deviceID: binding.deviceID); XCTFail("expired readiness") } catch {}
    }
    func testRevocationCancelsPendingFlowAndOldGenerationCannotReopen() async throws {
        let (hub, key, binding) = fixture(); let old = try await ready(hub, key: key, binding: binding)
        let pending = Task { try await hub.open(readiness: old, service: .lockdown, port: 62078) }
        _ = try await demand(hub, ready: old)
        await hub.revoke(bindingID: binding.id)
        do { _ = try await pending.value; XCTFail("revoked pending flow") } catch {}
        let fresh = try await ready(hub, key: key, binding: binding, generation: "new")
        XCTAssertNotEqual(fresh.id, old.id)
        do { _ = try await hub.open(readiness: old, service: .afc, port: 32100); XCTFail("old generation") } catch {}
        do { _ = try await hub.open(readiness: fresh, service: .lockdown, port: 80); XCTFail("arbitrary port") } catch {}
    }
    private func unix(_ path: String) throws -> CodeUnixStream {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodeFailure("socket") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw CodeFailure("connect") }
        return CodeUnixStream(fd: fd)
    }
    private func brokerRequest(token: String, fullClose: Bool = false) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["version": 1, "token": token, "service": "afc", "port": 32100, "fullCloseOnEOF": fullClose])
        var result = Data([76, 67, 65, 49]); let n = UInt32(body.count)
        result.append(contentsOf: [UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        result.append(body); return result
    }
    func testPrivateUnixBrokerConnectsHelperToProvenPhoneAndCleansUp() async throws {
        let (hub, key, binding) = fixture(); let ready = try await ready(hub, key: key, binding: binding)
        let broker = try CodeUnixAppleBroker(hub: hub, readiness: ready)
        defer { broker.close() }
        let socketMode = try FileManager.default.attributesOfItem(atPath: broker.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(socketMode?.intValue, 0o600)
        let helper = try unix(broker.path); defer { helper.close() }
        try await helper.write(brokerRequest(token: broker.token))
        let acknowledged = Task { try await helper.read(exactly: 1) }
        let demand = try await demand(hub, ready: ready)
        let pair = ReverseTestStream.pair()
        let serving = Task {
            try await CodeReversePhoneFlow.serve(demand: demand, readiness: ready, accountPeerID: "account", macPeerID: "mac",
                identityKey: key.publicKey.x963Representation, sign: { try self.sign($0, key: key) }, stream: pair.1,
                available: {}, openEndpoint: { _, _ in ReverseEchoSocket() })
        }
        let frame = try await CodeInstallFrame.read(from: pair.0)
        try await hub.accept(JSONDecoder().decode(CodeReverseStreamProof.self, from: frame.payload), stream: pair.0, peer: "account")
        let ack = try await acknowledged.value; XCTAssertEqual(ack, Data([1]))
        let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        try await helper.write(payload); let echoed = try await helper.read(exactly: payload.count); XCTAssertEqual(echoed, payload)
        try await helper.halfClose(); let eof = try await helper.read(maximum: 1); XCTAssertNil(eof)
        try await serving.value
        broker.close(); XCTAssertFalse(FileManager.default.fileExists(atPath: broker.directory.path))
    }
    func testFullHelperExitClosesAFlowWhoseAppleSocketNeverSendsEOF() async throws {
        let (hub, key, binding) = fixture(); let ready = try await ready(hub, key: key, binding: binding)
        let broker = try CodeUnixAppleBroker(hub: hub, readiness: ready); defer { broker.close() }
        let helper = try unix(broker.path); defer { helper.close() }
        try await helper.write(brokerRequest(token: broker.token, fullClose: true))
        let demand = try await demand(hub, ready: ready)
        let pair = ReverseTestStream.pair(); let completed = expectation(description: "full close terminates the phone proxy")
        let serving = Task {
            do {
                try await CodeReversePhoneFlow.serve(demand: demand, readiness: ready, accountPeerID: "account", macPeerID: "mac",
                    identityKey: key.publicKey.x963Representation, sign: { try self.sign($0, key: key) }, stream: pair.1,
                    available: {}, openEndpoint: { _, _ in ReverseNeverEndingSocket() })
            } catch {}
            completed.fulfill()
        }
        let frame = try await CodeInstallFrame.read(from: pair.0)
        try await hub.accept(JSONDecoder().decode(CodeReverseStreamProof.self, from: frame.payload), stream: pair.0, peer: "account")
        _ = try await helper.read(exactly: 1); helper.close()
        await fulfillment(of: [completed], timeout: 2)
        serving.cancel(); broker.close()
    }
    func testPrivateUnixBrokerRejectsWrongTokenWithoutDemandingPhoneFlow() async throws {
        let (hub, key, binding) = fixture(); let ready = try await ready(hub, key: key, binding: binding)
        let broker = try CodeUnixAppleBroker(hub: hub, readiness: ready); defer { broker.close() }
        let helper = try unix(broker.path); defer { helper.close() }
        try await helper.write(brokerRequest(token: String(repeating: "x", count: 64)))
        do { _ = try await helper.read(exactly: 1); XCTFail("accepted invalid private token") } catch {}
        var control = CodeReverseControl(); control.sessionID = ready.id; control.generation = ready.generation; control.token = ready.token; control.sequence = 1
        let flows = try await hub.poll(control, peer: "account"); XCTAssertTrue(flows.isEmpty)
    }
    func testFramedSocketRejectsReplayedRenewalAndExpiresBlockedReads() async throws {
        let pair = ReverseTestStream.pair(); let clock = ReverseClock()
        let socket = CodeReverseFramedSocket(stream: pair.0, uptime: { clock.now }, released: {})
        let renewal = try JSONEncoder().encode(CodeReverseRenewal(sequence: 1))
        try await pair.1.write(CodeInstallFrame(.renew, payload: renewal).encoded())
        try await pair.1.write(CodeInstallFrame(.renew, payload: renewal).encoded())
        do { _ = try await socket.read(maximum: 1); XCTFail("replayed stream renewal") } catch {}
        socket.close()
        let second = ReverseTestStream.pair()
        let expiring = CodeReverseFramedSocket(stream: second.0, uptime: { clock.now }, released: {})
        let blocked = Task { try await expiring.read(maximum: 10) }
        clock.now = 61
        do { _ = try await blocked.value; XCTFail("expired stream") } catch {}
        expiring.close(); second.1.close()
    }
}
private final class ReverseClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: TimeInterval = 0
    var now: TimeInterval { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
}
private actor ReverseTestBuffer {
    var data = Data(); var closed = false
    func append(_ bytes: Data) throws { if closed { throw CodeFailure("closed") }; data.append(bytes) }
    func close() { closed = true }
    func read(_ size: Int, partial: Bool = false) async throws -> Data? {
        if size == 0 { return Data() }
        while (partial ? data.isEmpty : data.count < size) && !closed { try await Task.sleep(for: .milliseconds(1)) }
        if data.isEmpty && closed { return nil }
        if !partial && data.count < size { throw CodeFailure("closed") }
        let result = Data(data.prefix(min(size, data.count))); data.removeFirst(result.count); return result
    }
}
private final class ReverseTestStream: CodeInstallStream, @unchecked Sendable {
    let input: ReverseTestBuffer, output: ReverseTestBuffer
    init(_ input: ReverseTestBuffer, _ output: ReverseTestBuffer) { self.input = input; self.output = output }
    static func pair() -> (ReverseTestStream, ReverseTestStream) { let a = ReverseTestBuffer(), b = ReverseTestBuffer(); return (ReverseTestStream(a, b), ReverseTestStream(b, a)) }
    func read(exactly count: Int) async throws -> Data { guard let data = try await input.read(count) else { throw CodeFailure("closed") }; return data }
    func write(_ data: Data) async throws { try await output.append(data) }
    func close() { Task { await input.close(); await output.close() } }
}
private final class ReverseEchoSocket: CodeDeviceFlowSocket, @unchecked Sendable {
    let buffer = ReverseTestBuffer()
    func read(maximum: Int) async throws -> Data? { try await buffer.read(maximum, partial: true) }
    func write(_ data: Data) async throws { try await buffer.append(data) }
    func halfClose() async throws { await buffer.close() }
    func close() { Task { await buffer.close() } }
}

private final class ReverseNeverEndingSocket: CodeDeviceFlowSocket, @unchecked Sendable {
    let buffer = ReverseTestBuffer()
    func read(maximum: Int) async throws -> Data? { try await buffer.read(maximum, partial: true) }
    func write(_ data: Data) async throws {}
    func halfClose() async throws {}
    func close() { Task { await buffer.close() } }
}
