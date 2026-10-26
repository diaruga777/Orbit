import Foundation

public struct OrbitAppletNotification: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public func validate() throws {
        guard !id.isEmpty, id.count <= 128, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 100, body.count <= 2000 else { throw OrbitWidgetError("Notifications need an id, title (100 characters), and body (2000 characters).") }
    }
}

public struct OrbitAppletPollState: Codable, Sendable {
    public var digest: String
    public var nextAttempt: Date
    public var lastSuccess: Date?
    public var failure: String?
    public var delivered: [String] = []
    public var pending: [OrbitAppletNotification] = []
}

/// One invocation per stored applet, including foreground controls and background
/// checks. The durable outbox can retry without re-running JavaScript.
public actor OrbitAppletRunner {
    public static let shared = OrbitAppletRunner()
    private var active = Set<String>()
    public init() {}
    private func key(_ script: OrbitWidgetScript, _ store: OrbitWidgetStore) -> String { store.executionScope + "/" + script.id }
    public func run(script: OrbitWidgetScript, store: OrbitWidgetStore, event: OrbitAppletEvent? = nil) async throws -> OrbitWidgetOutput {
        let key = key(script, store)
        guard active.insert(key).inserted else { throw OrbitWidgetError("This applet is checking. Try again in a moment.") }
        defer { active.remove(key) }
        let output = try await OrbitAppletRuntime.run(script: script, storage: store.storage(script.id), event: event)
        try Task.checkCancellation()
        try store.save(output, script: script, family: "large")
        return output
    }
    public func nextCheck(store: OrbitWidgetStore, scriptIDs: Set<String>? = nil, now: Date = Date()) throws -> Date? {
        try store.scripts().compactMap { script -> Date? in
            guard scriptIDs?.contains(script.id) ?? true else { return nil }
            guard try OrbitAppletDefinition.parse(script.source).pollHours != nil else { return nil }
            guard let state = try store.pollingState(script.id), state.digest == OrbitWidgetDefinition.digest(script.source) else { return now }
            return state.pending.isEmpty ? state.nextAttempt : min(state.nextAttempt, now.addingTimeInterval(900))
        }.min()
    }
    @discardableResult public func check(script: OrbitWidgetScript, store: OrbitWidgetStore, now: Date = Date(),
                                        deliver: @Sendable (OrbitAppletNotification) async throws -> Void) async throws -> Bool {
        let definition = try OrbitAppletDefinition.parse(script.source)
        guard let hours = definition.pollHours else { return false }
        let key = key(script, store)
        guard active.insert(key).inserted else { return false }
        defer { active.remove(key) }
        guard try store.script(script.id)?.source == script.source else { return false }
        let digest = OrbitWidgetDefinition.digest(script.source)
        var state = try store.pollingState(script.id) ?? .init(digest: digest, nextAttempt: now)
        if state.digest != digest {
            let delivered = state.delivered
            state = .init(digest: digest, nextAttempt: now)
            state.delivered = delivered
        }
        if state.nextAttempt <= now {
            // Persist a short lease before execution, so interruption cannot spin.
            state.nextAttempt = now.addingTimeInterval(900)
            try store.savePolling(state, storage: store.storage(script.id), script: script)
            do {
                let output = try await OrbitAppletRuntime.run(script: script, storage: store.storage(script.id), poll: true, now: now)
                try Task.checkCancellation()
                state.nextAttempt = now.addingTimeInterval(hours * 3600)
                state.lastSuccess = now; state.failure = nil
                for notice in output.notifications ?? [] where !state.delivered.contains(notice.id) && !state.pending.contains(where: { $0.id == notice.id }) {
                    // At most one notification per poll, with a bounded durable outbox.
                    guard state.pending.count < 8 else { throw OrbitWidgetError("Notifications are waiting. Try again later.") }
                    state.pending.append(notice)
                }
                try store.savePolling(state, storage: output.storage, script: script)
            } catch {
                // Reload the lease: failed output must never leak notification
                // mutations into the committed outbox or advance lastSuccess.
                state = try store.pollingState(script.id) ?? .init(digest: digest, nextAttempt: now)
                state.nextAttempt = now.addingTimeInterval(900)
                state.failure = String(error.localizedDescription.prefix(2000))
                try store.savePolling(state, storage: store.storage(script.id), script: script)
                throw error
            }
        }
        while let notice = state.pending.first {
            try Task.checkCancellation()
            guard try store.script(script.id)?.source == script.source else { return false }
            try await deliver(notice)
            state.pending.removeFirst(); state.delivered.append(notice.id)
            state.delivered = Array(state.delivered.suffix(64))
            try store.savePolling(state, storage: store.storage(script.id), script: script)
        }
        return true
    }
}
