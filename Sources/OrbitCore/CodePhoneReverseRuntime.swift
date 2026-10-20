import Foundation

/// Scene-independent, bounded phone-side readiness. Control RPCs carry demands
/// and proofs; each Apple flow opens its own phone-initiated authenticated stream.
public actor CodePhoneReverseRuntime {
    private let client: CodeClient
    private let identity: CodeInstallEndpointIdentity
    private let account: String
    private let mac: String
    private let generation: String
    private let provider: CodeInstallProvider
    private let dial: @Sendable () async throws -> any CodeInstallStream
    private let available: @Sendable () async throws -> Void
    private let open: @Sendable (CodeAppleStreamService, UInt16) async throws -> any CodeDeviceFlowSocket
    private let record: @Sendable (String) -> Void
    private var readiness: CodeReverseReadiness?
    private var poller: Task<Void, Never>?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var streams: [String: any CodeInstallStream] = [:]
    private var stopped = false
    public init(client: CodeClient, identity: CodeInstallEndpointIdentity, accountPeerID: String, macPeerID: String,
                generation: String, provider: CodeInstallProvider,
                dial: @escaping @Sendable () async throws -> any CodeInstallStream,
                available: @escaping @Sendable () async throws -> Void,
                open: @escaping @Sendable (CodeAppleStreamService, UInt16) async throws -> any CodeDeviceFlowSocket,
                record: @escaping @Sendable (String) -> Void = { _ in }) {
        self.client = client; self.identity = identity; account = accountPeerID; mac = macPeerID
        self.generation = generation; self.provider = provider; self.dial = dial; self.available = available; self.open = open; self.record = record
    }
    @discardableResult public func start() async throws -> Bool {
        guard !stopped, readiness == nil else { throw CodeFailure("Phone readiness already started or ended.") }
        try await available()
        guard let binding = try await client.call(CodeRequest(.endpointStatus)).endpointBindings?.first(where: { $0.publicKey == identity.publicKey }) else { record("notEnrolled"); return false }
        var control = CodeReverseControl(); control.bindingID = binding.id; control.generation = generation; control.provider = provider
        var request = CodeRequest(.endpointReadyBegin); request.reverse = control
        guard let bytes = try await client.call(request).reverseChallenge else { throw CodeFailure("The Mac did not return a readiness challenge.") }
        let challenge = try JSONDecoder().decode(CodeReverseChallenge.self, from: bytes)
        guard challenge.version == 1, challenge.purpose == "readiness", challenge.bindingID == binding.id,
              challenge.accountPeerID == account, challenge.deviceID == binding.deviceID, challenge.generation == generation else { throw CodeFailure("Phone readiness identity changed.") }
        control.sessionID = challenge.id; control.signature = try identity.sign(challenge: bytes)
        request = CodeRequest(.endpointReadyFinish); request.reverse = control
        guard let value = try await client.call(request).reverseReadiness, value.id == challenge.id,
              value.bindingID == binding.id, value.deviceID == binding.deviceID, value.generation == generation,
              value.provider == provider, !stopped else { throw CodeFailure("Phone readiness was not confirmed.") }
        readiness = value; record("ready")
        poller = Task { await self.poll(value) }
        return true
    }
    public func stop() {
        guard !stopped else { return }; stopped = true
        poller?.cancel(); poller = nil
        tasks.values.forEach { $0.cancel() }; streams.values.forEach { $0.close() }
        tasks.removeAll(); streams.removeAll()
        if let value = readiness {
            var control = CodeReverseControl(); control.sessionID = value.id; control.token = value.token
            var request = CodeRequest(.endpointStop); request.reverse = control
            let client = client
            Task { _ = try? await client.call(request) }
        }
        readiness = nil; record("stopped")
    }
    private func poll(_ value: CodeReverseReadiness) async {
        var sequence: UInt64 = 0
        do {
            while !Task.isCancelled && !stopped {
                try await available(); sequence += 1
                var control = CodeReverseControl(); control.sessionID = value.id; control.token = value.token
                control.generation = value.generation; control.sequence = sequence
                var request = CodeRequest(.endpointPoll); request.reverse = control
                let demands = try await client.call(request).reverseFlows ?? []
                guard demands.count <= 8 else { throw CodeFailure("Too many Apple service requests.") }
                for demand in demands where tasks[demand.id] == nil && tasks.count < 4 && !stopped {
                    tasks[demand.id] = Task { await self.serve(demand, readiness: value) }
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch { record(error is CancellationError ? "cancelled" : "unavailable"); stop() }
    }
    private func serve(_ demand: CodeReverseFlowDemand, readiness: CodeReverseReadiness) async {
        defer { tasks[demand.id] = nil; streams[demand.id]?.close(); streams[demand.id] = nil }
        do {
            let stream = try await dial()
            guard !stopped, !Task.isCancelled else { stream.close(); throw CancellationError() }
            streams[demand.id] = stream
            let identity = identity
            try await CodeReversePhoneFlow.serve(demand: demand, readiness: readiness, accountPeerID: account, macPeerID: mac,
                identityKey: identity.publicKey, sign: { try identity.sign(challenge: $0) }, stream: stream, available: available, openEndpoint: open)
            record("flowCompleted")
        } catch { record(error is CancellationError ? "flowCancelled" : "flowUnavailable") }
    }
}
