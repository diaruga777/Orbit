import XCTest
import IrohLib
import OrbitCore
import OrbitWire
@testable import OrbitTransport

final class OrbitRPCDeliveryTests: XCTestCase {
    /// Real local QUIC, no discovery/relay, Mac catalog, Apple access or phone.
    func testLargeCatalogReplySurvivesIrohDeliveryAndClientClose() async throws {
        let server = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal(), alpns: [OrbitDumbpipe.alpn]))
        let client = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal(), alpns: [OrbitDumbpipe.alpn]))
        let payload = Data(repeating: 65, count: 3 * 1024 * 1024)
        let serving = Task {
            let incoming = try XCTUnwrap(await server.acceptNext())
            let connection = try await incoming.accept().connect()
            let stream = OrbitIrohStream(connection: connection, stream: try await connection.acceptBi())
            let timer = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { stream.close() } }
            defer { timer.cancel(); stream.close() }
            let magic = try await stream.read(exactly: 4); XCTAssertEqual(magic, OrbitRPC.magic)
            _ = try await OrbitRPC.read(from: stream)
            try await OrbitRPC.reply(payload, stream: stream)
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
