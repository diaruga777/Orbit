import Foundation
import CryptoKit
import OrbitCore

/// Implementations must verify Apple's actual physical UDID on every operation.
/// The container belongs to the configured Code application, never to the caller.
public protocol CodeEndpointContainerAccess: Sendable {
    func writeChallenge(_ data: Data, id: String, deviceID: String) async throws
    func readProof(id: String, deviceID: String) async throws -> Data
}

public actor CodeEndpointEnrollmentService {
    private struct Snapshot: Codable { var version = 1; var bindings: [CodeEndpointBinding] }
    private struct Pending {
        var peer: String; var request: CodeEndpointEnrollmentRequest; var challenge: Data
        var deadline: TimeInterval; var generation: UUID; var ready = false
    }
    private let file: URL
    private let access: any CodeEndpointContainerAccess
    private let clock: @Sendable () -> TimeInterval
    private var pending: [String: Pending] = [:]
    private var bindings: [CodeEndpointBinding]
    public init(root: URL, access: any CodeEndpointContainerAccess,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.file = root.appendingPathComponent("endpoint-bindings-v1.json"); self.access = access; self.clock = clock
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: file.path) {
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512_000 else { throw CodeFailure("Invalid phone authorization store.") }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            guard snapshot.version == 1, snapshot.bindings.count <= 32 else { throw CodeFailure("Unsupported phone authorization store.") }
            bindings = snapshot.bindings
        } else { bindings = [] }
    }
    public func status(peer: String) throws -> [CodeEndpointBinding] {
        try validatePeer(peer); return bindings.filter { $0.accountPeerID == peer }
    }
    public func begin(_ request: CodeEndpointEnrollmentRequest, peer: String) async throws -> CodeEndpointChallengeReceipt {
        try validatePeer(peer)
        _ = try CodeEndpointEnrollment.path(id: request.id, proof: false)
        guard !request.deviceID.isEmpty, request.deviceID.count <= 128,
              request.deviceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              request.publicKey.count == 65,
              (try? P256.Signing.PublicKey(x963Representation: request.publicKey)) != nil else { throw CodeFailure("Choose a physical phone and a valid installation key.") }
        pending = pending.filter { $0.value.deadline > clock() }
        if let old = pending[request.id] {
            guard old.peer == peer, old.request.deviceID == request.deviceID, old.request.publicKey == request.publicKey,
                  old.ready else { throw CodeFailure("Phone authorization is already in progress or this ID was reused.") }
            return CodeEndpointChallengeReceipt(id: request.id, deviceID: request.deviceID)
        }
        guard !bindings.contains(where: { $0.id == request.id }), pending.count < 8 else { throw CodeFailure("Start a new phone authorization after the current attempt finishes.") }
        let nonce = Data(SHA256.hash(data: Data((UUID().uuidString + UUID().uuidString).utf8)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let challenge = try encoder.encode(CodeEndpointChallenge(id: request.id, accountPeerID: peer, deviceID: request.deviceID, publicKey: request.publicKey, nonce: nonce))
        let generation = UUID()
        pending[request.id] = Pending(peer: peer, request: request, challenge: challenge, deadline: clock() + 300, generation: generation)
        do {
            try await access.writeChallenge(challenge, id: request.id, deviceID: request.deviceID)
            guard var current = pending[request.id], current.generation == generation, current.deadline > clock() else { throw CodeFailure("Phone authorization expired or was revoked.") }
            current.ready = true; pending[request.id] = current
            return CodeEndpointChallengeReceipt(id: request.id, deviceID: request.deviceID)
        } catch {
            if pending[request.id]?.generation == generation { pending.removeValue(forKey: request.id) }
            throw error
        }
    }
    public func finish(id: String, peer: String) async throws -> CodeEndpointBinding {
        try validatePeer(peer)
        if let binding = bindings.first(where: { $0.id == id && $0.accountPeerID == peer }) { return binding }
        guard let attempt = pending[id], attempt.peer == peer, attempt.ready, attempt.deadline > clock() else { throw CodeFailure("Phone authorization expired. Start again while this phone is connected to your Mac.") }
        let data = try await access.readProof(id: id, deviceID: attempt.request.deviceID)
        // Revalidate after suspension: forgetting/revoking the account invalidates
        // in-flight Apple reads too. Wall-clock changes cannot extend a challenge.
        guard let current = pending[id], current.generation == attempt.generation, current.deadline > clock(), data.count <= 8192 else { throw CodeFailure("Phone authorization expired or was revoked.") }
        let proof = try JSONDecoder().decode(CodeEndpointProof.self, from: data)
        guard proof.challenge == attempt.challenge,
              CodeInstallEndpointIdentity.verify(signature: proof.signature, challenge: proof.challenge, publicKey: attempt.request.publicKey) else { throw CodeFailure("This phone’s installation key could not be verified.") }
        let binding = CodeEndpointBinding(id: id, accountPeerID: peer, deviceID: attempt.request.deviceID, publicKey: attempt.request.publicKey)
        var updated = bindings.filter { !($0.accountPeerID == peer && ($0.deviceID == binding.deviceID || $0.publicKey == binding.publicKey)) }
        guard updated.count < 32 else { throw CodeFailure("Remove an old phone authorization before adding another.") }
        updated.append(binding)
        try persist(updated); bindings = updated; pending.removeValue(forKey: id)
        return binding
    }
    public func revoke(id: String, peer: String) throws {
        try validatePeer(peer)
        // A revoke during begin/finish invalidates pending work, even if the
        // persistent binding has not been written yet.
        if pending[id]?.peer == peer { pending.removeValue(forKey: id) }
        let updated = bindings.filter { !($0.id == id && $0.accountPeerID == peer) }
        try persist(updated); bindings = updated
    }
    public func revokeAll() throws {
        pending.removeAll(); try persist([]); bindings.removeAll()
    }
    private func persist(_ updated: [CodeEndpointBinding]) throws {
        let data = try JSONEncoder().encode(Snapshot(bindings: updated))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
    }
    private func validatePeer(_ peer: String) throws {
        guard !peer.isEmpty, peer.count <= 256 else { throw CodeFailure("An authenticated Orbit account is required to authorize a phone.") }
    }
}
