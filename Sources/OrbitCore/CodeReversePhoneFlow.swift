import Foundation

/// The phone has already verified its readiness receipt against its own key and
/// binding. Its host supplies only an owned numeric Apple-service socket factory.
public enum CodeReversePhoneFlow {
    public static func serve(demand: CodeReverseFlowDemand, readiness: CodeReverseReadiness,
                             accountPeerID: String, macPeerID: String, identityKey: Data,
                             sign: @Sendable (Data) throws -> Data,
                             stream: any CodeInstallStream,
                             available: @escaping @Sendable () async throws -> Void,
                             openEndpoint: @escaping @Sendable (CodeAppleStreamService, UInt16) async throws -> any CodeDeviceFlowSocket) async throws {
        defer { stream.close() }
        guard demand.sessionID == readiness.id, demand.bindingID == readiness.bindingID, demand.deviceID == readiness.deviceID,
              demand.generation == readiness.generation, demand.service.permits(port: demand.port),
              UUID(uuidString: demand.id) != nil else { throw CodeFailure("Apple stream request targets a different phone.") }
        let challenge = try JSONDecoder().decode(CodeReverseChallenge.self, from: demand.challenge)
        guard challenge.version == 1, challenge.purpose == "apple-flow", challenge.id == demand.id,
              challenge.accountPeerID == accountPeerID, challenge.bindingID == demand.bindingID, challenge.deviceID == demand.deviceID,
              challenge.generation == demand.generation, challenge.service == demand.service, challenge.port == demand.port else { throw CodeFailure("Apple stream request identity changed.") }
        try await available()
        let proof = CodeReverseStreamProof(flowID: demand.id, sessionID: demand.sessionID, signature: try sign(demand.challenge))
        guard CodeInstallEndpointIdentity.verify(signature: proof.signature, challenge: demand.challenge, publicKey: identityKey) else { throw CodeFailure("This phone’s installation key changed.") }
        let authority = CodeDeviceFlowAuthority()
        let grant = try await authority.issue(peerID: macPeerID, verifiedDeviceID: demand.deviceID,
            verifiedEndpointIDs: [demand.id], generation: demand.generation, seconds: 60)
        try await withTaskCancellationHandler {
            try await stream.write(CodeInstallFrame(.reverseProof, payload: JSONEncoder().encode(proof)).encoded())
            try await stream.write(CodeInstallFrame(.reverseGrant, payload: JSONEncoder().encode(grant)).encoded())
            let heartbeat = Task {
                var sequence: UInt64 = 0
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(20)); try await available()
                        sequence += 1
                        try await authority.renew(grant, peerID: macPeerID, sequence: sequence, seconds: 60)
                        try await stream.write(CodeInstallFrame(.renew, payload: JSONEncoder().encode(CodeReverseRenewal(sequence: sequence))).encoded())
                    }
                } catch { stream.close(); await authority.revoke(sessionID: grant.sessionID) }
            }
            defer { heartbeat.cancel() }
            try await CodeDeviceFlowProxy.serve(stream: stream, authenticatedPeerID: macPeerID, authority: authority) { endpoint in
                guard endpoint == demand.id else { throw CodeFailure("Unexpected Apple endpoint.") }
                try await available()
                return try await openEndpoint(demand.service, demand.port)
            }
            await authority.revoke(sessionID: grant.sessionID)
        } onCancel: { stream.close(); Task { await authority.revoke(sessionID: grant.sessionID) } }
    }
}
