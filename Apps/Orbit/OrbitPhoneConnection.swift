import Foundation
import OrbitCore
import OrbitWire
import OrbitTransport

final class OrbitPhoneConnection: @unchecked Sendable {
    static let shared = OrbitPhoneConnection()
    private let routeSync = OrbitRouteSync()
    private let forwarding = OrbitPhoneForwarding()
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbit", isDirectory: true) }
    let transport = OrbitGoTransport(configuration: .init(stateDirectory: root.appendingPathComponent("Identity"), requestLocalNetworkAccess: true))
    var pairingCode: String {
        get { UserDefaults.standard.string(forKey: "Orbit.pairing") ?? "" }
        set {
            OrbitDiagnostics.shared.record("connection", "pairing_changed")
            if newValue != pairingCode { UserDefaults.standard.removeObject(forKey: "Orbit.connectionRoutes") }
            UserDefaults.standard.set(newValue, forKey: "Orbit.pairing")
        }
    }
    var localID: String { UserDefaults.standard.string(forKey: "Orbit.localID") ?? "" }
    var peerID: String { (try? OrbitPairingCode(string: pairingCode).deviceID.description) ?? "unpaired" }
    lazy var client = CodeClient { [self] request in
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any] ?? [:]
        return try JSONSerialization.data(withJSONObject: await rpc("code", object))
    }
    func offerInstallWindow(seconds: Int) async {
        let deadline = Date().addingTimeInterval(Double(seconds))
        while !Task.isCancelled, Date() < deadline, !pairingCode.isEmpty {
            await syncRoutes()
            let snapshot = savedRoutes
            let generation = peerID
            do {
                let (_, route) = try await reachableRoute()
                let account = snapshot?.accountPeerID ?? localID
                let provider: CodeInstallProvider
                if case .dumbpipe = route { provider = .dumbpipe }
                else if case .relay = route { provider = .syncthing }
                else { provider = .local }
                let local = provider == .dumbpipe ? try await OrbitDumbpipe.shared.start() : try transport.identity()
                let runtime = CodePhoneReverseRuntime(client: client,
                    identity: try CodeInstallEndpointIdentity(service: (Bundle.main.bundleIdentifier ?? "org.example.orbit.ios") + ".installation"),
                    accountPeerID: account.isEmpty ? local.description : account, macPeerID: generation,
                    generation: generation, provider: provider, dial: { [self] in
                        // Every Apple stream uses the currently reachable, independently pinned route.
                        let (code, route) = try await reachableRoute()
                        return OrbitInstallStream(authenticatedStream: try await transport.dial(route, expecting: code.deviceID))
                    }, available: { try Task.checkCancellation() }, open: { service, port in
                        try await OrbitLocalAppleServices.openVerifiedService(service, port: port, interfaces: ["en0", "en1"])
                    })
                guard await forwarding.begin(runtime) else { return }
                do {
                    if try await runtime.start() {
                        while !Task.isCancelled, Date() < deadline, snapshot == savedRoutes, generation == peerID, await runtime.isActive {
                            try await Task.sleep(for: .seconds(2))
                        }
                    }
                } catch { OrbitDiagnostics.shared.error("connection", "forwarding_failed", error) }
                await runtime.stop(); await forwarding.end(runtime)
            } catch { OrbitDiagnostics.shared.error("connection", "readiness_failed", error) }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }
    func prepareIdentity() async throws {
        let code = try OrbitPairingCode(string: pairingCode)
        let id: DeviceID
        if code.addresses.contains(where: { if case .dumbpipe = $0 { return true }; return false }) {
            id = try await OrbitDumbpipe.shared.start(secretURL: Self.root.appendingPathComponent("Identity/iroh.key"))
        } else { id = try transport.identity() }
        UserDefaults.standard.set(id.description, forKey: "Orbit.localID")
    }
    var savedRoutes: OrbitConnectionRoutes? {
        guard let data = UserDefaults.standard.data(forKey: "Orbit.connectionRoutes") else { return nil }
        return try? JSONDecoder().decode(OrbitConnectionRoutes.self, from: data)
    }
    func syncRoutes() async {
        let original = pairingCode
        guard !original.isEmpty else { return }
        do {
            try await routeSync.synchronize(request: { [self] params in
                guard pairingCode == original else { throw CancellationError() }
                let object = try await rpc("connection_routes", params)
                return try JSONDecoder().decode(OrbitConnectionRoutes.self, from: JSONSerialization.data(withJSONObject: object))
            }, identity: { [self] provider in
                if provider == "dumbpipe" {
                    return try await OrbitDumbpipe.shared.start(secretURL: Self.root.appendingPathComponent("Identity/iroh.key"))
                }
                return try transport.identity()
            }, save: { [self] routes in
                guard pairingCode == original else { throw CancellationError() }
                UserDefaults.standard.set(try JSONEncoder().encode(routes), forKey: "Orbit.connectionRoutes")
                if routes.provider != "dumbpipe" { try await OrbitDumbpipe.shared.stop() }
            })
        } catch { OrbitDiagnostics.shared.error("connection", "route_sync_failed", error) }
    }
    private var codes: [OrbitPairingCode] {
        let original = try? OrbitPairingCode(string: pairingCode)
        let updated = (try? savedRoutes?.validated()) ?? []
        return updated.isEmpty ? (original.map { [$0] } ?? []) : updated
    }
    private func prepare(_ route: OrbitPeerAddress) async throws {
        if case .dumbpipe = route { _ = try await OrbitDumbpipe.shared.start(secretURL: Self.root.appendingPathComponent("Identity/iroh.key")) }
    }
    private func reachableRoute() async throws -> (OrbitPairingCode, OrbitPeerAddress) {
        var last: Error = CodeFailure("Your Mac is unavailable.")
        let payload = try JSONSerialization.data(withJSONObject: ["method": "connection_status"])
        for code in codes {
            for route in code.addresses {
                do {
                    try await prepare(route)
                    let stream = try await transport.dial(route, expecting: code.deviceID)
                    let response = try JSONSerialization.jsonObject(with: await OrbitRPC.exchange(payload, stream: stream, timeout: 5)) as? [String: Any]
                    if let error = response?["error"] as? String { throw CodeFailure(error) }
                    return (code, route)
                } catch { last = error }
            }
        }
        throw last
    }
    private let logSync = OrbitDiagnosticSync()
    func syncDiagnostics() async {
        guard await logSync.begin() else { return }
        let original = pairingCode, peer = peerID
        let key = "Orbit.diagnostics.cursor." + peer
        do {
            guard !original.isEmpty else { await logSync.end(); return }
            // Bound each foreground pass, then resume from the durable acknowledgement.
            for _ in 0..<4 {
                let events = OrbitDiagnostics.shared.events(after: UserDefaults.standard.string(forKey: key), maximum: 12)
                guard !events.isEmpty, pairingCode == original, !Task.isCancelled else { break }
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))
                let result = try await rpc("diagnostics_upload", ["events": object]) as? [String: Any]
                guard pairingCode == original, result?["acknowledged"] as? String == events.last?.id else { break }
                UserDefaults.standard.set(events.last?.id, forKey: key)
            }
        } catch { /* Offline journals remain on the phone and retry next foreground pass. */ }
        await logSync.end()
    }
    func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        let trace = UUID().uuidString, started = Date()
        var fields = ["method": method, "request": trace]
        if let operation = params["operation"] as? String { fields["operation"] = operation }
        if let id = params["id"] as? String { fields["actionID"] = id }
        let logging = method != "diagnostics_upload"
        if logging { OrbitDiagnostics.shared.record("rpc", "started", fields) }
        do {
            guard !pairingCode.isEmpty else { throw CodeFailure("Connect your Mac first.") }
            let original = pairingCode
            let payload = try JSONSerialization.data(withJSONObject: ["method": method, "params": params, "trace": trace])
            var last: Error = CodeFailure("Your Mac is unavailable.")
            for code in codes {
                for route in code.addresses {
                    try Task.checkCancellation()
                    guard pairingCode == original else { throw CancellationError() }
                    let stream: any BEPByteStream
                    do {
                        try await prepare(route)
                        stream = try await transport.dial(route, expecting: code.deviceID)
                    } catch {
                        last = error
                        if logging { OrbitDiagnostics.shared.error("rpc", "dial_failed", error, fields) }
                        continue
                    }
                    fields["route"] = routeKind(route)
                    let data: Data
                    do { data = try await OrbitRPC.exchange(payload, stream: stream, timeout: method == "targets" ? 30 : 180) }
                    catch {
                        if logging { OrbitDiagnostics.shared.error("rpc", "exchange_failed", error, fields) }
                        // The Mac may have accepted a mutation. Never resend a build/save
                        // just because its reply was lost. Refresh reads durable job state.
                        if !Self.readOnly(method, params) { throw CodeFailure("The Mac’s reply was interrupted. Check Apps before trying again.") }
                        last = error; continue
                    }
                    guard pairingCode == original else { throw CancellationError() }
                    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          response["result"] != nil || response["error"] is String else { throw CodeFailure("Your Mac sent an invalid reply. Update Orbit Mac and retry.") }
                    if let message = response["error"] as? String { throw CodeFailure(message) }
                    fields["milliseconds"] = String(Int(Date().timeIntervalSince(started) * 1000)); fields["bytes"] = String(data.count)
                    if logging { OrbitDiagnostics.shared.record("rpc", "completed", fields) }
                    return response["result"] ?? NSNull()
                }
            }
            throw last
        } catch {
            if logging { OrbitDiagnostics.shared.error("rpc", "failed", error, fields) }
            throw error
        }
    }
    private static func readOnly(_ method: String, _ params: [String: Any]) -> Bool {
        if method == "code" {
            return ["open", "schemes", "apps", "devices", "branches", "job", "overnightCapabilities", "overnightStatus", "overnightDiagnostics", "endpointStatus"].contains(params["operation"] as? String ?? "")
        }
        return ["mac_update_status", "targets", "status", "job", "connection_status", "browse", "widgets", "applets", "installed_apps", "projects_detect", "project_preview", "project_apps", "repo_search", "repo_inspect", "artifact", "diagnostics_upload"].contains(method)
    }
    private func routeKind(_ route: OrbitPeerAddress) -> String {
        switch route { case .dumbpipe: return "iroh"; case .relay: return "relay"; case .tcp: return "tcp"; case .tailscale: return "tailscale" }
    }

}
private actor OrbitPhoneForwarding {
    private var active: CodePhoneReverseRuntime?
    func begin(_ value: CodePhoneReverseRuntime) -> Bool { guard active == nil else { return false }; active = value; return true }
    func end(_ value: CodePhoneReverseRuntime) { if active === value { active = nil } }
}

private actor OrbitDiagnosticSync {
    private var active = false
    func begin() -> Bool { guard !active else { return false }; active = true; return true }
    func end() { active = false }
}
