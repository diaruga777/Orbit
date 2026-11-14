import XCTest
import OrbitCore
import OrbitWire
import OrbitTransport
@testable import OrbitHost

final class OrbitConnectionTests: XCTestCase {
    private func identity(_ byte: UInt8) throws -> DeviceID { try DeviceID(bytes: Data(repeating: byte, count: 32)) }
    private func request(_ host: OrbitHost, _ method: String, _ params: [String: Any] = [:], peer: String? = nil) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        let response = await host.handle(data, peer: peer)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }
    func testLiveConfigurationStartsBeforeSavingAndFailureKeepsWorkingSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let calls = ConnectionCalls()
        await host.installConnectionHandler { config in
            await calls.record(config.provider)
            if config.provider == "syncthing" { throw CodeFailure("Relay is unavailable") }
            return [config.provider]
        }
        let enabled = try await request(host, "configure", ["provider": "dumbpipe"])
        let result = try XCTUnwrap(enabled["result"] as? [String: Any])
        XCTAssertEqual(result["restartRequired"] as? Bool, false)
        let current = await host.configuration; XCTAssertEqual(current.provider, "dumbpipe")
        let failed = try await request(host, "configure", ["provider": "syncthing", "relay": "relay://relay.invalid:22067/?id=TEST"])
        XCTAssertEqual(failed["error"] as? String, "Relay is unavailable")
        let preserved = await host.configuration; XCTAssertEqual(preserved.provider, "dumbpipe")
        let disk = try JSONDecoder().decode(OrbitConfiguration.self, from: Data(contentsOf: root.appendingPathComponent("config.json")))
        XCTAssertEqual(disk.provider, "dumbpipe")
        _ = try await request(host, "configure", ["provider": "local"])
        let recorded = await calls.providers
        XCTAssertEqual(recorded, ["local", "dumbpipe", "syncthing", "local"])
    }
    func testAuthenticatedRouteHandoffPreservesAccountAcrossRestartAndRevoke() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = try identity(1).description, alternate = try identity(2).description
        let mac = try identity(3)
        let local = OrbitPairingCode(deviceID: mac, addresses: [.tcp(host: "192.168.1.2", port: 49210)]).text
        let remoteID = try identity(4)
        let remote = OrbitPairingCode(deviceID: remoteID, addresses: [.dumbpipe(endpoint: remoteID.bytes.map { String(format: "%02x", $0) }.joined())]).text
        var host: OrbitHost? = try OrbitHost(root: root)
        await host!.installConnectionHandler { config in config.provider == "dumbpipe" ? [remote, local] : [local] }
        await host!.openPairing(); try await host!.trust(phone)
        _ = try await request(host!, "configure", ["provider": "dumbpipe"])
        let untrusted = try await request(host!, "connection_routes", ["transportPeerID": alternate], peer: "stranger")
        XCTAssertNotNil(untrusted["error"])
        let before = await host!.isTrusted(alternate); XCTAssertFalse(before)
        let exchange = try await request(host!, "connection_routes", ["transportPeerID": alternate, "receivedCodes": [remote, local]], peer: phone)
        let routes = try JSONDecoder().decode(OrbitConnectionRoutes.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(exchange["result"])))
        XCTAssertEqual(routes.accountPeerID, phone)
        XCTAssertEqual(try routes.validated().map(\.deviceID), [remoteID, mac])
        let canonical = await host!.canonicalPeer(alternate); XCTAssertEqual(canonical, phone)
        let status = try await request(host!, "connection_status")
        XCTAssertEqual((status["result"] as? [String: Any])?["syncedPhones"] as? Int, 1)
        host = nil
        let restarted = try OrbitHost(root: root)
        let aliasTrusted = await restarted.isTrusted(alternate); XCTAssertTrue(aliasTrusted)
        let after = try await request(restarted, "connection_routes", peer: alternate)
        XCTAssertEqual((after["result"] as? [String: Any])?["accountPeerID"] as? String, phone)
        _ = try await request(restarted, "forget")
        let revoked = await restarted.isTrusted(alternate); XCTAssertFalse(revoked)
        let rejected = try await request(restarted, "connection_routes", peer: alternate)
        XCTAssertNotNil(rejected["error"])
    }
    func testSwitchFromIrohToTailscaleKeepsPairedPhoneAndPrioritizesTailnet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let irohPhone = try identity(1), tlsPhone = try identity(2)
        let irohMac = try identity(3), tlsMac = try identity(4)
        let iroh = OrbitPairingCode(deviceID: irohMac, addresses: [.dumbpipe(endpoint: irohMac.bytes.map { String(format: "%02x", $0) }.joined())])
        let lan = OrbitPeerAddress.tcp(host: "192.168.1.2", port: 49210)
        let tailnet = OrbitPeerAddress.tcp(host: "mac.tailnet.invalid", port: 49210)
        await host.installConnectionHandler { config in
            let tcp = config.tcpPairingCode(deviceID: tlsMac, localAddresses: [lan])
            return config.provider == "dumbpipe" ? [iroh.text, tcp.text] : [tcp.text]
        }
        await host.openPairing()
        try await host.trust(irohPhone.description)
        let enabled = try await request(host, "configure", ["provider": "dumbpipe"])
        XCTAssertNil(enabled["error"])
        let sync = OrbitRouteSync()
        try await sync.synchronize(request: { params in
            let peer = params["receivedCodes"] == nil ? irohPhone : tlsPhone
            let data = try JSONSerialization.data(withJSONObject: ["method": "connection_routes", "params": params])
            let reply = await host.handle(data, peer: peer.description)
            return try XCTUnwrap(JSONDecoder().decode([String: OrbitConnectionRoutes].self, from: reply)["result"])
        }, identity: { _ in irohPhone }, tcpIdentity: { tlsPhone }, save: { _ in })
        let account = await host.canonicalPeer(tlsPhone.description)
        XCTAssertEqual(account, irohPhone.description)

        let switched = try await request(host, "configure", ["provider": "tailscale", "address": "mac.tailnet.invalid"])
        XCTAssertNil(switched["error"])
        let reply = try await request(host, "connection_routes", peer: tlsPhone.description)
        let routes = try JSONDecoder().decode(OrbitConnectionRoutes.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(reply["result"])))
        XCTAssertEqual(routes.provider, "tailscale")
        XCTAssertEqual(routes.accountPeerID, irohPhone.description)
        let code = try XCTUnwrap(routes.validated().first)
        XCTAssertEqual(code.deviceID, tlsMac)
        XCTAssertEqual(code.addresses, [tailnet, lan])
        XCTAssertEqual(routes.pairingCodes.count, 1)
    }
    func testCannotClaimAnotherPhoneAndOnlyTCPIsAcceptedForTailscale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let first = try identity(1).description, second = try identity(2).description, alias = try identity(3).description
        await host.openPairing(); try await host.trust(first); try await host.trust(second)
        for key in [second, alias] {
            if key == alias { _ = try await request(host, "connection_routes", ["transportPeerID": alias], peer: second) }
            let rejected = try await request(host, "connection_routes", ["transportPeerID": key], peer: first)
            XCTAssertNotNil(rejected["error"])
        }
        let collision = try await request(host, "connection_routes", ["transportPeerID": try identity(4).description, "tcpPeerID": second], peer: first)
        XCTAssertNotNil(collision["error"])
        let unchanged = await host.isTrusted(try identity(4).description)
        XCTAssertFalse(unchanged)
        for address in ["relay://relay.invalid/?id=TEST", "dumbpipe://" + String(repeating: "a", count: 64), "https://mac.invalid", "tcp://user@mac.invalid:49210", "0.0.0.0", "mac.invalid:0"] {
            let rejected = try await request(host, "configure", ["provider": "tailscale", "address": address])
            XCTAssertNotNil(rejected["error"])
        }
        var config = OrbitConfiguration()
        config.provider = "tailscale"
        for (address, host, port) in [("tcp://mac.tailnet.invalid:49210", "mac.tailnet.invalid", 49210),
                                      (" 100.80.1.2 ", "100.80.1.2", 49210),
                                      ("[fd7a:115c:a1e0::1]:49211", "fd7a:115c:a1e0::1", 49211),
                                      ("fd7a:115c:a1e0::1", "fd7a:115c:a1e0::1", 49210)] {
            config.address = address
            XCTAssertNoThrow(try config.validateConnection(requireAddress: true))
            let code = try config.tcpPairingCode(deviceID: identity(5), localAddresses: [])
            XCTAssertEqual(try OrbitPairingCode(string: code.text).addresses, [.tcp(host: host, port: UInt16(port))])
        }
    }
    func testPhoneSyncRequiresConfirmedPinsAndEnrollmentBeforeSaving() async throws {
        let phone = try identity(1), mac = try identity(2)
        let code = OrbitPairingCode(deviceID: mac, addresses: [.tcp(host: "192.168.1.2", port: 49210)]).text
        let routes = OrbitConnectionRoutes(provider: "local", pairingCodes: [code], accountPeerID: phone.description)
        let exchange = RouteExchange(routes: [routes, routes, routes])
        let sync = OrbitRouteSync()
        try await sync.synchronize(request: { try await exchange.request($0) }, identity: { _ in phone }, save: { await exchange.save($0) })
        let saved = await exchange.saved
        XCTAssertEqual(saved, routes)
        let enrolled = await exchange.enrolled
        XCTAssertEqual(enrolled, phone.description)
        let acknowledged = await exchange.acknowledged; XCTAssertTrue(acknowledged)
        var changed = routes; changed.accountPeerID = mac.description
        let raced = RouteExchange(routes: [routes, changed])
        do {
            try await sync.synchronize(request: { try await raced.request($0) }, identity: { _ in phone }, save: { await raced.save($0) })
            XCTFail("Changed account must not replace saved pins")
        } catch { }
        let rejected = await raced.saved; XCTAssertNil(rejected)
        let disconnected = RouteExchange(routes: [routes])
        do {
            try await sync.synchronize(request: { try await disconnected.request($0) }, identity: { _ in phone }, save: { await disconnected.save($0) })
            XCTFail("A lost enrollment reply must not replace saved pins")
        } catch { }
        let retained = await disconnected.saved; XCTAssertNil(retained)
    }
    func testRemoteSetupUsesSavedRoutesWithoutRequiringLiveConnection() throws {
        let mac = try identity(9), phone = try identity(8)
        let local = OrbitPairingCode(deviceID: mac, addresses: [.tcp(host: "192.168.1.2", port: 49210)]).text
        let remote = OrbitPairingCode(deviceID: mac, addresses: [.dumbpipe(endpoint: mac.bytes.map { String(format: "%02x", $0) }.joined())]).text
        XCTAssertFalse(OrbitConnectionRoutes.hasRemoteConnection(pairingCode: "", savedRoutes: nil))
        XCTAssertFalse(OrbitConnectionRoutes.hasRemoteConnection(pairingCode: local, savedRoutes: nil))
        XCTAssertTrue(OrbitConnectionRoutes.hasRemoteConnection(pairingCode: remote, savedRoutes: nil))
        let relay = OrbitPairingCode(deviceID: mac, addresses: [.relay(url: URL(string: "relay://relay.invalid:22067")!)]).text
        XCTAssertTrue(OrbitConnectionRoutes.hasRemoteConnection(pairingCode: relay, savedRoutes: nil))
        for provider in ["dumbpipe", "tailscale", "syncthing"] {
            let routes = OrbitConnectionRoutes(provider: provider, pairingCodes: [provider == "dumbpipe" ? remote : local], accountPeerID: phone.description)
            let restored = try JSONDecoder().decode(OrbitConnectionRoutes.self, from: JSONEncoder().encode(routes))
            // The original LAN pairing remains unchanged after authenticated route sync.
            XCTAssertTrue(OrbitConnectionRoutes.hasRemoteConnection(pairingCode: local, savedRoutes: restored))
            XCTAssertFalse(OrbitConnectionRoutes.hasRemoteConnection(pairingCode: "", savedRoutes: restored))
        }
        let disabled = OrbitConnectionRoutes(provider: "local", pairingCodes: [local], accountPeerID: phone.description)
        XCTAssertFalse(OrbitConnectionRoutes.hasRemoteConnection(pairingCode: remote, savedRoutes: disabled))
        let empty = OrbitConnectionRoutes(provider: "dumbpipe", pairingCodes: [], accountPeerID: phone.description)
        XCTAssertFalse(OrbitConnectionRoutes.hasRemoteConnection(pairingCode: local, savedRoutes: empty))
        let invalid = OrbitConnectionRoutes(provider: "dumbpipe", pairingCodes: ["invalid"], accountPeerID: phone.description)
        XCTAssertFalse(OrbitConnectionRoutes.hasRemoteConnection(pairingCode: remote, savedRoutes: invalid))
    }
    func testIrohRelayHintSurvivesPairingCodeAndKeepsTheSamePin() throws {
        let mac = try identity(9)
        let endpoint = mac.bytes.map { String(format: "%02x", $0) }.joined()
        let route = OrbitPeerAddress.dumbpipe(endpoint: endpoint)
        let relay = "https://relay.example.com/"
        let old = OrbitPairingCode(deviceID: mac, addresses: [route])
        let new = OrbitPairingCode(deviceID: mac, addresses: [route], irohRelay: relay)
        XCTAssertEqual(try OrbitPairingCode(string: new.text), new)
        XCTAssertNil(try OrbitPairingCode(string: old.text).irohRelay)
        let decoded = try OrbitConnectionRoutes(provider: "dumbpipe", pairingCodes: [new.text], accountPeerID: mac.description).validated()
        XCTAssertEqual(decoded, [new])
        for invalid in ["http://relay.example.com", "https://user@relay.example.com", "https://relay.example.com/?secret=1"] {
            XCTAssertNil(OrbitPairingCode(deviceID: mac, addresses: [route], irohRelay: invalid).irohRelay)
        }
    }
    func testRouteUpdateRejectsMismatchedRemotePinAndIsBackwardCompatible() throws {
        let mac = try identity(9), other = try identity(10)
        let bad = OrbitPairingCode(deviceID: mac, addresses: [.dumbpipe(endpoint: other.bytes.map { String(format: "%02x", $0) }.joined())])
        XCTAssertThrowsError(try OrbitConnectionRoutes(provider: "dumbpipe", pairingCodes: [bad.text], accountPeerID: mac.description).validated())
        let config = try JSONDecoder().decode(OrbitConfiguration.self, from: JSONEncoder().encode(OrbitConfiguration()))
        XCTAssertNil(config.peerAliases)
    }
}
private actor ConnectionCalls {
    var providers: [String] = []
    func record(_ provider: String) { providers.append(provider) }
}

private actor RouteExchange {
    var routes: [OrbitConnectionRoutes]
    var saved: OrbitConnectionRoutes?
    var enrolled: String?
    var acknowledged = false
    init(routes: [OrbitConnectionRoutes]) { self.routes = routes }
    func request(_ params: [String: Any]) throws -> OrbitConnectionRoutes {
        guard !routes.isEmpty else { throw CodeFailure("Disconnected") }
        if let identity = params["transportPeerID"] as? String { enrolled = identity }
        if params["receivedCodes"] != nil {
            guard saved != nil else { throw CodeFailure("Phone acknowledged before saving") }
            acknowledged = true
        }
        return routes.removeFirst()
    }
    func save(_ value: OrbitConnectionRoutes) { saved = value }
}
