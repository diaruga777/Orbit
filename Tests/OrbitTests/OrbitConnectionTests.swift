import XCTest
import OrbitCore
import OrbitWire
@testable import OrbitHost

final class OrbitConnectionTests: XCTestCase {
    private func identity(_ byte: UInt8) throws -> DeviceID { try DeviceID(bytes: Data(repeating: byte, count: 32)) }
    private func request(_ host: OrbitHost, _ method: String, _ params: [String: Any] = [:], peer: String? = nil) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: await host.handle(data, peer: peer)) as? [String: Any])
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
        for address in ["relay://relay.invalid/?id=TEST", "dumbpipe://" + String(repeating: "a", count: 64), "https://mac.invalid"] {
            let rejected = try await request(host, "configure", ["provider": "tailscale", "address": address])
            XCTAssertNotNil(rejected["error"])
        }
        var config = OrbitConfiguration(); config.provider = "tailscale"; config.address = "tcp://mac.tailnet.invalid:49210"
        XCTAssertNoThrow(try config.validateConnection(requireAddress: true))
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
