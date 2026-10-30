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
        guard !pairingCode.isEmpty else { return }
        do {
            await syncRoutes()
            // Resolve the available route before offering Apple streams. Keep the original account pin.
            let (code, route) = try await reachableRoute()
            let account = savedRoutes?.accountPeerID ?? localID
            let provider: CodeInstallProvider
            if case .dumbpipe = route { provider = .dumbpipe }
            else if case .relay = route { provider = .syncthing }
            else { provider = .local }
            if case .dumbpipe = route { _ = try await OrbitDumbpipe.shared.start(secretURL: Self.root.appendingPathComponent("Identity/iroh.key")) }
            let local = provider == .dumbpipe ? try await OrbitDumbpipe.shared.start() : try transport.identity()
            let runtime = CodePhoneReverseRuntime(client: client,
                identity: try CodeInstallEndpointIdentity(service: (Bundle.main.bundleIdentifier ?? "org.example.orbit.ios") + ".installation"),
                accountPeerID: account.isEmpty ? local.description : account, macPeerID: peerID,
                generation: peerID, provider: provider, dial: { [transport] in
                    OrbitInstallStream(authenticatedStream: try await transport.dial(route, expecting: code.deviceID))
                }, available: { try Task.checkCancellation() }, open: { service, port in
                    try await OrbitLocalAppleServices.openVerifiedService(service, port: port, interfaces: ["en0", "en1"])
                })
            guard await forwarding.begin(runtime) else { return }
            do {
                if try await runtime.start() { try await Task.sleep(for: .seconds(seconds)) }
            } catch { }
            await runtime.stop(); await forwarding.end(runtime)
        } catch { }
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
        } catch { /* Offline and older clients keep their last authenticated routes. */ }
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
                    _ = try await OrbitRPC.exchange(payload, stream: stream)
                    return (code, route)
                } catch { last = error }
            }
        }
        throw last
    }
    func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        guard !pairingCode.isEmpty else { throw CodeFailure("Connect your Mac first.") }
        let payload = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        var last: Error = CodeFailure("Your Mac is unavailable.")
        for code in codes {
            for route in code.addresses {
                let response: [String: Any]
                do {
                    try await prepare(route)
                    let stream = try await transport.dial(route, expecting: code.deviceID)
                    response = try JSONSerialization.jsonObject(with: await OrbitRPC.exchange(payload, stream: stream)) as? [String: Any] ?? [:]
                } catch { last = error; continue }
                // Application errors must not replay mutations on another route.
                if let message = response["error"] as? String { throw CodeFailure(message) }
                return response["result"] ?? NSNull()
            }
        }
        throw last
    }
}
