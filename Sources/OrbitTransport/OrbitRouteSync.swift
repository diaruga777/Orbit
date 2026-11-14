import Foundation
import OrbitWire
import OrbitCore

/// Transfer transport pins only through an existing authenticated connection.
public actor OrbitRouteSync {
    private var syncing = false
    public init() {}
    public func synchronize(
        request: @escaping @Sendable ([String: Any]) async throws -> OrbitConnectionRoutes,
        identity: @escaping @Sendable (String) async throws -> DeviceID,
        tcpIdentity: (@Sendable () throws -> DeviceID)? = nil,
        save: @escaping @Sendable (OrbitConnectionRoutes) async throws -> Void
    ) async throws {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        let proposed = try await request([:])
        _ = try proposed.validated()
        let local = try await identity(proposed.provider)
        var enrollment = ["transportPeerID": local.description]
        // An iroh-paired phone also needs a trusted TLS identity when iroh is turned off.
        if proposed.provider == "dumbpipe", let tcpIdentity {
            enrollment["tcpPeerID"] = try tcpIdentity().description
        }
        let confirmed = try await request(enrollment)
        _ = try confirmed.validated()
        guard confirmed.accountPeerID == proposed.accountPeerID, confirmed.provider == proposed.provider,
              confirmed.pairingCodes == proposed.pairingCodes else {
            throw CodeFailure("Connection settings changed. They’ll sync on the next connection.")
        }
        try await save(confirmed)
        // Public progress reflects a persisted phone snapshot, not just a delivered proposal.
        _ = try? await request(["receivedCodes": confirmed.pairingCodes])
    }
}
