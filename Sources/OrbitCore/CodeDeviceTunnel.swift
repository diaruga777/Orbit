import Foundation

/// Provider-neutral stream, supplied only after peer authentication. A device
/// flow uses a separate TLS session, never BEP file blocks or an existing RPC.
public protocol CodeInstallStream: AnyObject, Sendable {
    func read(exactly count: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close()
}
public protocol CodeDeviceFlowSocket: AnyObject, Sendable {
    func read(maximum: Int) async throws -> Data?
    func write(_ data: Data) async throws
    func halfClose() async throws
    func close()
}
public struct CodeDeviceFlowOpen: Codable, Equatable, Sendable {
    public var version = 1
    public var flowID = UUID().uuidString
    public var sessionID: String
    public var generation: String
    public var leaseToken: String
    public var endpointID: String
    public var targetDeviceID: String
    public init(sessionID: String, generation: String, leaseToken: String, endpointID: String, targetDeviceID: String) {
        self.sessionID = sessionID; self.generation = generation; self.leaseToken = leaseToken
        self.endpointID = endpointID; self.targetDeviceID = targetDeviceID
    }
}
public struct CodeInstallFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable { case open = 1, data, halfClose, close, accepted, reverseProof, reverseGrant, renew }
    public static let maximumPayload = 64 * 1024
    public var kind: Kind
    public var payload: Data
    public init(_ kind: Kind, payload: Data = Data()) { self.kind = kind; self.payload = payload }
    public func encoded() throws -> Data {
        guard payload.count <= Self.maximumPayload else { throw CodeFailure("Device flow frame exceeds its limit.") }
        var result = Data([0x4c, 0x43, 0x44, 0x46, 1, kind.rawValue]) // LCDF v1
        let count = UInt32(payload.count)
        result.append(contentsOf: [UInt8(count >> 24), UInt8(truncatingIfNeeded: count >> 16), UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
        result.append(payload); return result
    }
    public static func read(from stream: any CodeInstallStream) async throws -> Self {
        let header = try await stream.read(exactly: 10)
        guard header.count == 10, Array(header.prefix(5)) == [0x4c, 0x43, 0x44, 0x46, 1], let kind = Kind(rawValue: header[5]) else { throw CodeFailure("Unsupported device flow protocol.") }
        let size = header[6..<10].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size <= maximumPayload else { throw CodeFailure("Device flow frame exceeds its limit.") }
        if [.halfClose, .close, .accepted].contains(kind), size != 0 { throw CodeFailure("Invalid device flow control frame.") }
        let payload = try await stream.read(exactly: Int(size))
        guard payload.count == Int(size) else { throw CodeFailure("Incomplete device flow frame.") }
        return Self(kind, payload: payload)
    }
}

/// Local monotonic deadlines. Tokens cannot be reused across sessions,
/// generations, targets or revoked peers. The host injects a bound credential
/// check after every fresh TLS/Apple handshake, independently of relay IDs.
public actor CodeDeviceFlowAuthority {
    private struct Lease {
        var token: String
        var generation: String
        var peerID: String
        var deviceID: String
        var endpointIDs: Set<String>
        var deadline: TimeInterval
        var hardDeadline: TimeInterval
        var renewal: UInt64 = 0
        var usedFlowIDs: Set<String> = []
        var bytes: Int64 = 0
        var flows: [String: @Sendable () -> Void] = [:]
    }
    private var leases: [String: Lease] = [:]
    private let uptime: @Sendable () -> TimeInterval
    public init(uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.uptime = uptime }
    public func issue(peerID: String, verifiedDeviceID: String, verifiedEndpointIDs: Set<String>, generation: String, seconds: TimeInterval = 60) throws -> CodeDeviceFlowOpen {
        expire()
        guard !peerID.isEmpty, !verifiedDeviceID.isEmpty, !verifiedEndpointIDs.isEmpty, verifiedEndpointIDs.count <= 16,
              seconds > 0, seconds <= 120, leases.count < 8 else { throw CodeFailure("Invalid device forwarding authorization.") }
        let id = UUID().uuidString, token = UUID().uuidString + UUID().uuidString
        leases[id] = Lease(token: token, generation: generation, peerID: peerID, deviceID: verifiedDeviceID,
            endpointIDs: verifiedEndpointIDs, deadline: uptime() + seconds, hardDeadline: uptime() + 900)
        return CodeDeviceFlowOpen(sessionID: id, generation: generation, leaseToken: token, endpointID: verifiedEndpointIDs.sorted()[0], targetDeviceID: verifiedDeviceID)
    }
    public func renew(_ open: CodeDeviceFlowOpen, peerID: String, sequence: UInt64, seconds: TimeInterval) throws {
        var lease = try valid(open, peerID: peerID)
        guard sequence > lease.renewal, seconds > 0, seconds <= 120 else { throw CodeFailure("Stale device forwarding renewal.") }
        lease.renewal = sequence; lease.deadline = min(lease.hardDeadline, uptime() + seconds); leases[open.sessionID] = lease
    }
    public func acquire(_ open: CodeDeviceFlowOpen, peerID: String, close: @escaping @Sendable () -> Void) throws -> String {
        var lease = try valid(open, peerID: peerID)
        guard lease.flows.count < 8, lease.usedFlowIDs.count < 256, !lease.usedFlowIDs.contains(open.flowID) else { throw CodeFailure("Too many device service flows.") }
        lease.usedFlowIDs.insert(open.flowID)
        let flow = UUID().uuidString; lease.flows[flow] = close; leases[open.sessionID] = lease; return flow
    }
    public func attach(_ flow: String, open: CodeDeviceFlowOpen, peerID: String, close: @escaping @Sendable () -> Void) throws {
        var lease = try valid(open, peerID: peerID)
        guard lease.flows[flow] != nil else { throw CodeFailure("Device flow is no longer active.") }
        lease.flows[flow] = close; leases[open.sessionID] = lease
    }
    public func consume(_ bytes: Int, open: CodeDeviceFlowOpen, peerID: String) throws {
        var lease = try valid(open, peerID: peerID)
        guard bytes >= 0, bytes <= CodeInstallFrame.maximumPayload, lease.bytes <= 8 * 1024 * 1024 * 1024 - Int64(bytes) else { throw CodeFailure("Device forwarding byte limit reached.") }
        lease.bytes += Int64(bytes); leases[open.sessionID] = lease
    }
    public func release(_ flow: String, sessionID: String) { leases[sessionID]?.flows.removeValue(forKey: flow) }
    public func expire() {
        for (id, lease) in leases where uptime() >= lease.deadline { revoke(sessionID: id) }
    }
    public func revoke(sessionID: String) {
        guard let lease = leases.removeValue(forKey: sessionID) else { return }
        lease.flows.values.forEach { $0() }
    }
    public func revoke(peerID: String) {
        for (id, lease) in leases where lease.peerID == peerID { revoke(sessionID: id) }
    }
    private func valid(_ open: CodeDeviceFlowOpen, peerID: String) throws -> Lease {
        expire()
        guard open.version == 1, let lease = leases[open.sessionID], lease.token == open.leaseToken,
              lease.generation == open.generation, lease.peerID == peerID, lease.deviceID == open.targetDeviceID,
              lease.endpointIDs.contains(open.endpointID), uptime() < lease.deadline else { throw CodeFailure("Device forwarding authorization expired or changed.") }
        return lease
    }
}

/// Opaque forwarding with bounded reads and natural backpressure. A session's
/// endpoint IDs resolve only through a phone-local, validated Apple-service
/// registry supplied by the host. There is no wire-level host or port argument.
public enum CodeDeviceFlowProxy {
    public static func serve(stream: any CodeInstallStream, authenticatedPeerID: String, authority: CodeDeviceFlowAuthority,
                             openEndpoint: @escaping @Sendable (String) async throws -> any CodeDeviceFlowSocket) async throws {
        try await withTaskCancellationHandler {
            defer { stream.close() }
            let handshakeTimeout = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                stream.close()
            }
            defer { handshakeTimeout.cancel() }
            let first = try await CodeInstallFrame.read(from: stream)
            guard first.kind == .open else { throw CodeFailure("Device flow must begin with authorization.") }
            let open = try JSONDecoder().decode(CodeDeviceFlowOpen.self, from: first.payload)
            // Authorize before creating any device socket.
            let flow = try await authority.acquire(open, peerID: authenticatedPeerID, close: { stream.close() })
            handshakeTimeout.cancel()
            do {
                let socket = try await openEndpoint(open.endpointID)
                defer { socket.close() }
                try await authority.attach(flow, open: open, peerID: authenticatedPeerID, close: { stream.close(); socket.close() })
                do {
                    try await stream.write(CodeInstallFrame(.accepted).encoded())
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            while true {
                                try Task.checkCancellation()
                                let frame = try await CodeInstallFrame.read(from: stream)
                                try await authority.consume(frame.payload.count, open: open, peerID: authenticatedPeerID)
                                switch frame.kind {
                                case .data: try await socket.write(frame.payload)
                                case .halfClose: try await socket.halfClose(); return
                                case .close: socket.close(); return
                                default: throw CodeFailure("Unexpected device flow frame.")
                                }
                            }
                        }
                        group.addTask {
                            while let bytes = try await socket.read(maximum: CodeInstallFrame.maximumPayload) {
                                try Task.checkCancellation()
                                try await authority.consume(bytes.count, open: open, peerID: authenticatedPeerID)
                                try await stream.write(CodeInstallFrame(.data, payload: bytes).encoded())
                            }
                            try await stream.write(CodeInstallFrame(.halfClose).encoded())
                        }
                        // Independent watchdog closes blocked reads/writes on lease expiry.
                        group.addTask {
                            while !Task.isCancelled {
                                try await Task.sleep(for: .milliseconds(250))
                                try await authority.consume(0, open: open, peerID: authenticatedPeerID)
                            }
                        }
                        do {
                            _ = try await group.next(); _ = try await group.next()
                            group.cancelAll()
                        } catch {
                            stream.close(); socket.close(); group.cancelAll(); throw error
                        }
                    }
                } catch { throw error }
                await authority.release(flow, sessionID: open.sessionID)
            } catch { await authority.release(flow, sessionID: open.sessionID); throw error }
        } onCancel: { stream.close() }
    }
}
