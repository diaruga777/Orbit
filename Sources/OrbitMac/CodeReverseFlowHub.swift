import Foundation
import OrbitCore

/// Only authenticated companion composition can call this hub. Every readiness
/// and byte stream additionally proves the non-synchronizing enrolled phone key.
/// Memory-only leases never survive a Mac restart or account revocation.
public actor CodeReverseFlowHub {
    public typealias Lookup = @Sendable (String, String) async throws -> CodeEndpointBinding
    private struct PendingReady { var binding: CodeEndpointBinding; var peer: String; var generation: String; var provider: CodeInstallProvider; var bytes: Data; var deadline: TimeInterval }
    private struct Ready { var value: CodeReverseReadiness; var peer: String; var deadline: TimeInterval; var hardDeadline: TimeInterval; var sequence: UInt64 = 0; var active: [String: any CodeInstallStream] = [:] }
    private struct PendingFlow {
        var demand: CodeReverseFlowDemand; var deadline: TimeInterval
        var continuation: CheckedContinuation<any CodeDeviceFlowSocket, Error>
        var accepting = false
    }
    private let record: @Sendable (CodeOvernightDiagnosticEvent) -> Void
    private let lookup: Lookup
    private let uptime: @Sendable () -> TimeInterval
    private var challenges: [String: PendingReady] = [:]
    private var sessions: [String: Ready] = [:]
    private var flows: [String: PendingFlow] = [:]
    private var revision: UInt64 = 0
    public init(lookup: @escaping Lookup, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, record: @escaping @Sendable (CodeOvernightDiagnosticEvent) -> Void = { _ in }) { self.lookup = lookup; self.uptime = uptime; self.record = record }
    public func begin(_ control: CodeReverseControl, peer: String) async throws -> Data {
        expire()
        let version = revision
        let binding = try await lookup(control.bindingID, peer)
        guard version == revision, !control.generation.isEmpty, control.generation.count <= 128,
              [.local, .tailscale, .syncthing].contains(control.provider), challenges.count < 8 else { throw CodeFailure("Phone readiness is unavailable or changed.") }
        let id = UUID().uuidString
        let bytes = try JSONEncoder().encode(CodeReverseChallenge(purpose: "readiness", id: id, accountPeerID: peer, bindingID: binding.id, deviceID: binding.deviceID, generation: control.generation))
        challenges[id] = PendingReady(binding: binding, peer: peer, generation: control.generation, provider: control.provider, bytes: bytes, deadline: uptime() + 30)
        return bytes
    }
    public func finish(_ control: CodeReverseControl, peer: String) async throws -> CodeReverseReadiness {
        expire()
        guard let pending = challenges[control.sessionID], pending.peer == peer else { throw CodeFailure("Phone readiness proof expired.") }
        let binding = try await lookup(pending.binding.id, peer)
        guard let current = challenges[control.sessionID], current.bytes == pending.bytes, current.deadline > uptime(), binding == pending.binding,
              CodeInstallEndpointIdentity.verify(signature: control.signature, challenge: pending.bytes, publicKey: binding.publicKey) else { throw CodeFailure("This phone’s readiness proof could not be verified.") }
        challenges.removeValue(forKey: control.sessionID)
        for (id, session) in sessions where session.value.bindingID == binding.id { stop(id) }
        guard sessions.count < 4 else { throw CodeFailure("Too many phones are ready to install.") }
        let value = CodeReverseReadiness(id: control.sessionID, token: UUID().uuidString + UUID().uuidString,
            bindingID: binding.id, deviceID: binding.deviceID, generation: pending.generation, provider: pending.provider)
        sessions[value.id] = Ready(value: value, peer: peer, deadline: uptime() + 60, hardDeadline: uptime() + 900)
        record(CodeOvernightDiagnosticEvent(stage: "proxy.ready", correlationID: value.id, outcome: value.provider.rawValue))
        return value
    }
    public func poll(_ control: CodeReverseControl, peer: String) async throws -> [CodeReverseFlowDemand] {
        expire()
        guard var session = sessions[control.sessionID], session.peer == peer, session.value.token == control.token,
              session.value.generation == control.generation, control.sequence > session.sequence else { throw CodeFailure("Phone readiness expired or changed.") }
        _ = try await lookup(session.value.bindingID, peer)
        guard let current = sessions[control.sessionID], current.value == session.value, current.sequence == session.sequence else { throw CodeFailure("Phone readiness changed.") }
        session.sequence = control.sequence; session.deadline = min(session.hardDeadline, uptime() + 60); sessions[control.sessionID] = session
        return flows.values.filter { $0.demand.sessionID == control.sessionID && !$0.accepting }.map(\.demand)
    }
    public func stop(_ control: CodeReverseControl, peer: String) {
        guard let session = sessions[control.sessionID], session.peer == peer, session.value.token == control.token else { return }
        stop(control.sessionID)
    }
    public func revoke(bindingID: String? = nil) {
        revision &+= 1
        challenges = challenges.filter { bindingID != nil && $0.value.binding.id != bindingID }
        for (id, session) in sessions where bindingID == nil || session.value.bindingID == bindingID { stop(id) }
    }
    public func readiness(deviceID: String) async throws -> CodeReverseReadiness {
        expire()
        guard let session = sessions.values.first(where: { $0.value.deviceID == deviceID }) else { throw CodeFailure("The enrolled phone is not ready to forward an installation.") }
        _ = try await lookup(session.value.bindingID, session.peer)
        guard sessions[session.value.id]?.value == session.value else { throw CodeFailure("Phone readiness changed.") }
        return session.value
    }
    /// Called only by the private pinned Apple-helper broker. There is no Code
    /// RPC that accepts a service name/port and opens a socket for its caller.
    public func open(readiness: CodeReverseReadiness, service: CodeAppleStreamService, port: UInt16) async throws -> any CodeDeviceFlowSocket {
        expire()
        guard service.permits(port: port), let session = sessions[readiness.id], session.value == readiness,
              flows.count < 8, session.active.count + flows.values.filter({ $0.demand.sessionID == readiness.id }).count < 8 else { throw CodeFailure("Apple service forwarding is unavailable.") }
        let id = UUID().uuidString
        let bytes = try JSONEncoder().encode(CodeReverseChallenge(purpose: "apple-flow", id: id, accountPeerID: session.peer,
            bindingID: readiness.bindingID, deviceID: readiness.deviceID, generation: readiness.generation, service: service, port: port))
        let demand = CodeReverseFlowDemand(id: id, readiness: readiness, service: service, port: port, challenge: bytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                record(CodeOvernightDiagnosticEvent(stage: "proxy.flowRequested", correlationID: id, outcome: readiness.id + ";" + service.rawValue))
                flows[id] = PendingFlow(demand: demand, deadline: uptime() + 45, continuation: continuation)
                Task { try? await Task.sleep(for: .seconds(45)); self.fail(id, error: CodeFailure("The phone did not open its Apple service stream.")) }
            }
        } onCancel: { Task { await self.fail(id, error: CancellationError()) } }
    }
    /// A fresh, approved TLS connection starts with reverseProof. The companion
    /// has already demultiplexed it from BEP and supplies the actual TLS peer.
    public func accept(_ proof: CodeReverseStreamProof, stream: any CodeInstallStream, peer: String) async throws {
        expire()
        guard var pending = flows[proof.flowID], !pending.accepting, pending.demand.sessionID == proof.sessionID,
              let session = sessions[proof.sessionID], session.peer == peer, pending.deadline > uptime() else { stream.close(); throw CodeFailure("Unknown or replayed Apple service stream.") }
        pending.accepting = true; flows[proof.flowID] = pending
        sessions[proof.sessionID]?.active[proof.flowID] = stream
        do {
            let binding = try await lookup(session.value.bindingID, peer)
            guard flows[proof.flowID] != nil, sessions[proof.sessionID]?.value == session.value,
                  CodeInstallEndpointIdentity.verify(signature: proof.signature, challenge: pending.demand.challenge, publicKey: binding.publicKey) else { throw CodeFailure("Apple stream phone identity could not be verified.") }
            let timeout = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { stream.close() } }
            defer { timeout.cancel() }
            let frame = try await CodeInstallFrame.read(from: stream)
            guard frame.kind == .reverseGrant else { throw CodeFailure("Missing Apple stream authorization.") }
            let grant = try JSONDecoder().decode(CodeDeviceFlowOpen.self, from: frame.payload)
            guard grant.version == 1, grant.endpointID == pending.demand.id, grant.targetDeviceID == binding.deviceID,
                  grant.generation == session.value.generation, grant.leaseToken.count >= 32, grant.leaseToken.count <= 128 else { throw CodeFailure("Apple stream authorization targets a different phone.") }
            try await stream.write(CodeInstallFrame(.open, payload: JSONEncoder().encode(grant)).encoded())
            guard try await CodeInstallFrame.read(from: stream).kind == .accepted else { throw CodeFailure("The phone rejected the Apple service flow.") }
            guard let completed = flows.removeValue(forKey: proof.flowID), sessions[proof.sessionID] != nil else { throw CodeFailure("Apple stream authorization expired.") }
            sessions[proof.sessionID]?.active[proof.flowID] = stream
            record(CodeOvernightDiagnosticEvent(stage: "proxy.flowAuthenticated", correlationID: proof.flowID, outcome: proof.sessionID))
            let record = record
            let socket = CodeReverseFramedSocket(stream: stream, uptime: uptime, released: { [weak self] in Task { await self?.release(proof.flowID, session: proof.sessionID) } }, transferred: { bytes in
                record(CodeOvernightDiagnosticEvent(stage: "proxy.flowClosed", correlationID: proof.flowID, outcome: "totalBytes=" + String(bytes)))
            })
            completed.continuation.resume(returning: socket)
        } catch { stream.close(); release(proof.flowID, session: proof.sessionID); fail(proof.flowID, error: error); throw error }
    }
    public func expire() {
        for (id, value) in challenges where value.deadline <= uptime() { challenges.removeValue(forKey: id) }
        for (id, value) in flows where value.deadline <= uptime() { fail(id, error: CodeFailure("Apple stream request expired.")) }
        for (id, value) in sessions where value.deadline <= uptime() { stop(id) }
    }
    private func stop(_ id: String) {
        guard let old = sessions.removeValue(forKey: id) else { return }
        record(CodeOvernightDiagnosticEvent(stage: "proxy.stopped", correlationID: id, outcome: "closed"))
        old.active.values.forEach { $0.close() }
        for (flow, value) in flows where value.demand.sessionID == id { fail(flow, error: CodeFailure("Phone readiness ended.")) }
    }
    private func release(_ id: String, session: String) { sessions[session]?.active.removeValue(forKey: id) }
    private func fail(_ id: String, error: Error) { flows.removeValue(forKey: id)?.continuation.resume(throwing: error) }
}
