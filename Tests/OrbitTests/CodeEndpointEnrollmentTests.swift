import XCTest
import CryptoKit
@testable import OrbitCore
@testable import OrbitMac

final class CodeEndpointEnrollmentTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var time: TimeInterval = 100
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
        func advance(_ value: TimeInterval) { lock.lock(); time += value; lock.unlock() }
    }
    private actor Containers: CodeEndpointContainerAccess {
        let root: URL
        var reads = 0
        var paused = false
        var waiter: CheckedContinuation<Void, Never>?
        init(root: URL) { self.root = root }
        func container(_ device: String) -> URL { root.appendingPathComponent(device) }
        func writeChallenge(_ data: Data, id: String, deviceID: String) throws {
            let file = container(deviceID).appendingPathComponent(try CodeEndpointEnrollment.path(id: id, proof: false))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        func readProof(id: String, deviceID: String) async throws -> Data {
            reads += 1
            if paused { await withCheckedContinuation { waiter = $0 } }
            return try Data(contentsOf: container(deviceID).appendingPathComponent(try CodeEndpointEnrollment.path(id: id, proof: true)))
        }
        func pause() { paused = true }
        func resume() { paused = false; waiter?.resume(); waiter = nil }
    }
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func prove(_ receipt: CodeEndpointChallengeReceipt, root: URL, key: P256.Signing.PrivateKey) throws {
        try CodeEndpointEnrollment.writeProof(receipt: receipt, container: root, publicKey: key.publicKey.x963Representation) {
            try key.signature(for: Data("orbit-install-endpoint-v1\u{0}".utf8) + $0).derRepresentation
        }
    }
    func testAppleContainerRoundtripPersistsAndLostFinishReplyIsIdempotent() async throws {
        let root = try scratch(); let access = Containers(root: root.appendingPathComponent("phones"))
        let service = try CodeEndpointEnrollmentService(root: root.appendingPathComponent("mac"), access: access)
        let key = P256.Signing.PrivateKey()
        let request = CodeEndpointEnrollmentRequest(deviceID: "physical-A", publicKey: key.publicKey.x963Representation)
        let receipt = try await service.begin(request, peer: "tls-account")
        let duplicate = try await service.begin(request, peer: "tls-account")
        XCTAssertEqual(receipt.id, duplicate.id)
        try prove(receipt, root: await access.container("physical-A"), key: key)
        let binding = try await service.finish(id: receipt.id, peer: "tls-account")
        XCTAssertEqual(binding.deviceID, "physical-A")
        let second = try await service.finish(id: receipt.id, peer: "tls-account")
        XCTAssertEqual(second, binding)
        let reads = await access.reads; XCTAssertEqual(reads, 1)
        let restored = try CodeEndpointEnrollmentService(root: root.appendingPathComponent("mac"), access: access)
        let saved = try await restored.status(peer: "tls-account"); XCTAssertEqual(saved, [binding])
        let other = try await restored.status(peer: "other-account"); XCTAssertTrue(other.isEmpty)
        try await restored.revoke(id: binding.id, peer: "other-account")
        let stillSaved = try await restored.status(peer: "tls-account"); XCTAssertEqual(stillSaved, [binding])
        try await restored.revoke(id: binding.id, peer: "tls-account")
        let empty = try await restored.status(peer: "tls-account"); XCTAssertTrue(empty.isEmpty)
        let permission = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("mac/endpoint-bindings-v1.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permission?.intValue, 0o600)
    }
    func testOtherPhoneSharingAccountCannotSupplyProofOrSubstituteKey() async throws {
        let root = try scratch(); let access = Containers(root: root.appendingPathComponent("phones"))
        let service = try CodeEndpointEnrollmentService(root: root.appendingPathComponent("mac"), access: access)
        let owner = P256.Signing.PrivateKey(); let other = P256.Signing.PrivateKey()
        let request = CodeEndpointEnrollmentRequest(deviceID: "physical-A", publicKey: owner.publicKey.x963Representation)
        let receipt = try await service.begin(request, peer: "shared-account")
        XCTAssertThrowsError(try prove(receipt, root: root.appendingPathComponent("phones/physical-B"), key: owner))
        XCTAssertThrowsError(try prove(receipt, root: root.appendingPathComponent("phones/physical-A"), key: other))
        do { _ = try await service.finish(id: receipt.id, peer: "other-account"); XCTFail("accepted another account") } catch {}
        do { _ = try await service.finish(id: receipt.id, peer: "shared-account"); XCTFail("accepted missing Apple-container proof") } catch {}
        var reused = request; reused.publicKey = other.publicKey.x963Representation
        do { _ = try await service.begin(reused, peer: "shared-account"); XCTFail("accepted ID reuse") } catch {}
        try prove(receipt, root: root.appendingPathComponent("phones/physical-A"), key: owner)
        let binding = try await service.finish(id: receipt.id, peer: "shared-account")
        XCTAssertEqual(binding.publicKey, owner.publicKey.x963Representation)
    }
    func testMacRejectsTamperedSignatureAndChallengeEvenWhenProofFileExists() async throws {
        let root = try scratch(); let access = Containers(root: root.appendingPathComponent("phones"))
        let service = try CodeEndpointEnrollmentService(root: root.appendingPathComponent("mac"), access: access)
        let owner = P256.Signing.PrivateKey(); let impostor = P256.Signing.PrivateKey()
        let request = CodeEndpointEnrollmentRequest(deviceID: "physical-A", publicKey: owner.publicKey.x963Representation)
        let receipt = try await service.begin(request, peer: "account")
        let container = root.appendingPathComponent("phones/physical-A")
        let challenge = try Data(contentsOf: container.appendingPathComponent(try CodeEndpointEnrollment.path(id: receipt.id, proof: false)))
        let proofFile = container.appendingPathComponent(try CodeEndpointEnrollment.path(id: receipt.id, proof: true))
        let signature = try impostor.signature(for: Data("orbit-install-endpoint-v1\u{0}".utf8) + challenge).derRepresentation
        try JSONEncoder().encode(CodeEndpointProof(challenge: challenge, signature: signature)).write(to: proofFile)
        do { _ = try await service.finish(id: receipt.id, peer: "account"); XCTFail("accepted another key's signature") } catch {}
        let changed = challenge + Data([32])
        let otherSignature = try owner.signature(for: Data("orbit-install-endpoint-v1\u{0}".utf8) + changed).derRepresentation
        try JSONEncoder().encode(CodeEndpointProof(challenge: changed, signature: otherSignature)).write(to: proofFile)
        do { _ = try await service.finish(id: receipt.id, peer: "account"); XCTFail("accepted a changed signed challenge") } catch {}
        try prove(receipt, root: container, key: owner)
        _ = try await service.finish(id: receipt.id, peer: "account")
    }
    func testMonotonicExpiryAndRestartDropPendingChallenges() async throws {
        let root = try scratch(); let access = Containers(root: root.appendingPathComponent("phones")); let clock = Clock()
        let service = try CodeEndpointEnrollmentService(root: root.appendingPathComponent("mac"), access: access, clock: { clock.now() })
        let key = P256.Signing.PrivateKey(); let request = CodeEndpointEnrollmentRequest(deviceID: "physical-A", publicKey: key.publicKey.x963Representation)
        let receipt = try await service.begin(request, peer: "account")
        try prove(receipt, root: root.appendingPathComponent("phones/physical-A"), key: key)
        clock.advance(301)
        do { _ = try await service.finish(id: receipt.id, peer: "account"); XCTFail("accepted expired proof") } catch {}
        let restored = try CodeEndpointEnrollmentService(root: root.appendingPathComponent("mac"), access: access)
        do { _ = try await restored.finish(id: receipt.id, peer: "account"); XCTFail("restored an expired pending challenge") } catch {}
    }
    func testRevocationDuringAppleReadRejectsInFlightProof() async throws {
        let root = try scratch(); let access = Containers(root: root.appendingPathComponent("phones"))
        let service = try CodeEndpointEnrollmentService(root: root.appendingPathComponent("mac"), access: access)
        let key = P256.Signing.PrivateKey(); let request = CodeEndpointEnrollmentRequest(deviceID: "physical-A", publicKey: key.publicKey.x963Representation)
        let receipt = try await service.begin(request, peer: "account")
        try prove(receipt, root: root.appendingPathComponent("phones/physical-A"), key: key)
        await access.pause()
        let finish = Task { try await service.finish(id: receipt.id, peer: "account") }
        while await access.reads == 0 { await Task.yield() }
        try await service.revokeAll(); await access.resume()
        do { _ = try await finish.value; XCTFail("accepted revoked in-flight proof") } catch {}
        let empty = try await service.status(peer: "account"); XCTAssertTrue(empty.isEmpty)
    }
    func testPathAndKeyInputAreBoundedAndRPCRequiresAuthenticatedContext() async throws {
        XCTAssertThrowsError(try CodeEndpointEnrollment.path(id: "../../elsewhere", proof: true))
        let root = try scratch(); let access = Containers(root: root.appendingPathComponent("phones"))
        let service = try CodeEndpointEnrollmentService(root: root.appendingPathComponent("mac"), access: access)
        let bad = CodeEndpointEnrollmentRequest(deviceID: "../wrong", publicKey: Data(repeating: 1, count: 65))
        do { _ = try await service.begin(bad, peer: "account"); XCTFail("accepted unsafe input") } catch {}
        let rpc = try CodeService(root: root.appendingPathComponent("rpc"), installBundleID: "com.example.code")
        let request = try JSONEncoder().encode(CodeRequest(.endpointStatus))
        let denied = try JSONDecoder().decode(CodeResponse.self, from: await rpc.handle(request)); XCTAssertNotNil(denied.error)
        let allowed = try JSONDecoder().decode(CodeResponse.self, from: await rpc.handle(request, authenticatedPeerID: "account")); XCTAssertNil(allowed.error); XCTAssertEqual(allowed.endpointBindings, [])
    }
}
