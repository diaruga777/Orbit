import XCTest
import IrohLib
import OrbitCore
import OrbitWire
@testable import OrbitTransport

final class OrbitRPCDeliveryTests: XCTestCase {
    func testRelayHintConnectsWithoutEndpointDiscovery() async throws {
        guard ProcessInfo.processInfo.environment["ORBIT_TEST_IROH_RELAY"] == "1" else {
            throw XCTSkip("Set ORBIT_TEST_IROH_RELAY=1 to exercise a public relay with temporary endpoints.")
        }
        let options = EndpointOptions(preset: presetMinimal(), alpns: [OrbitDumbpipe.alpn], relayMode: .defaultMode())
        let server = try await Endpoint.bind(options: options)
        let client = try await Endpoint.bind(options: options)
        let serving = Task {
            let next = await server.acceptNext()
            let incoming = try XCTUnwrap(next)
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let stream = OrbitIrohStream(connection: connection, stream: try await connection.acceptBi())
            defer { stream.close() }
            let magic = try await stream.read(exactly: 4)
            XCTAssertEqual(magic, OrbitRPC.magic)
            let payload = try await OrbitRPC.read(from: stream)
            try await OrbitRPC.reply(payload, stream: stream)
        }
        do {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(15)
            while server.addr().relayUrl() == nil && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let relay = try XCTUnwrap(server.addr().relayUrl())
            let id = try DeviceID(bytes: server.id().toBytes())
            let key = id.bytes.map { String(format: "%02x", $0) }.joined()
            let wrong = try DeviceID(bytes: Data(repeating: 1, count: 32))
            do {
                _ = try await OrbitDumbpipe.dial(from: client, to: key, expecting: wrong, relay: relay)
                XCTFail("A relay hint must never override the endpoint pin")
            } catch let error as CodeFailure {
                XCTAssertTrue(error.localizedDescription.contains("paired Mac"))
            }

            let stream = try await OrbitDumbpipe.dial(from: client, to: key, expecting: id, relay: relay)
            let payload = Data("relay only".utf8)
            let result = try await OrbitRPC.exchange(payload, stream: stream, timeout: 10)
            XCTAssertEqual(result, payload)
            try await serving.value
        } catch {
            try? await client.close(); try? await server.close()
            _ = await serving.result
            throw error
        }
        try await client.close(); try await server.close()
    }

    /// Real local QUIC, no discovery/relay, Mac catalog, Apple access or phone.
    func testLargeCatalogReplySurvivesIrohDeliveryAndClientClose() async throws {
        let server = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal(), alpns: [OrbitDumbpipe.alpn]))
        let client = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal(), alpns: [OrbitDumbpipe.alpn]))
        let payload = Data(repeating: 65, count: 3 * 1024 * 1024)
        let serving = Task {
            let next = await server.acceptNext()
            let incoming = try XCTUnwrap(next)
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let stream = OrbitIrohStream(connection: connection, stream: try await connection.acceptBi())
            let timer = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { stream.close() } }
            defer { timer.cancel(); stream.close() }
            let magic = try await stream.read(exactly: 4); XCTAssertEqual(magic, OrbitRPC.magic)
            _ = try await OrbitRPC.read(from: stream)
            if ProcessInfo.processInfo.environment["ORBIT_TEST_IMMEDIATE_CLOSE"] == "1" {
                // Fault injection reproduces the historical write-then-close path.
                try await OrbitRPC.write(payload, to: stream)
            } else { try await OrbitRPC.reply(payload, stream: stream) }
        }
        do {
            let connection = try await client.connect(addr: server.addr(), alpn: OrbitDumbpipe.alpn)
            let stream = OrbitIrohStream(connection: connection, stream: try await connection.openBi())
            let result = try await OrbitRPC.exchange(Data("targets".utf8), stream: stream, timeout: 10)
            XCTAssertEqual(result, payload)
            try await serving.value
        } catch {
            serving.cancel(); try? await server.close(); try? await client.close(); throw error
        }
        try await server.close(); try await client.close()
    }
}
