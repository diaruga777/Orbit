import XCTest
import CryptoKit
import Darwin
import OrbitCore
@testable import OrbitMac
import OrbitWire
import OrbitTransport

/// Actual Go/TLS/private-relay -> LCDF phone proxy -> private Swift Unix broker
/// -> pinned Go Apple adapter. Only the Apple endpoint and IPA bytes are fixtures.
final class AppleRelayIntegrationTests: XCTestCase {
    func testPinnedAppleProtocolThroughPrivateRelayAndProductionBroker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["ORBIT_TEST_PRIVATE_RELAY"],
              let relay = URL(string: raw), relay.scheme == "relay",
              ["127.0.0.1", "[::1]", "::1"].contains(relay.host ?? ""),
              let executable = environment["ORBIT_TEST_APPLE_BINARY"] else {
            throw XCTSkip("run tools/apple-adapter/integration/run.sh with a private loopback relay")
        }
        for scenario in ["confirmed", "lost-reply", "wrong-udid", "wrong-certificate"] {
            try await run(scenario, relay: relay, executable: executable)
        }
    }

    private func run(_ scenario: String, relay: URL, executable: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppleRelay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("go.log")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: output); defer { try? log.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-test.run", "^TestSwiftPrivateRelayAppleIntegration$", "-test.v", "-test.timeout", "120s"]
        process.environment = ProcessInfo.processInfo.environment.merging(["ORBIT_TEST_APPLE_IPC": root.path, "ORBIT_TEST_APPLE_SCENARIO": scenario]) { _, new in new }
        process.standardOutput = log; process.standardError = log
        try process.run(); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let deadline = ProcessInfo.processInfo.systemUptime + 110
        let manifest = root.appendingPathComponent("fixture.json")
        while !FileManager.default.fileExists(atPath: manifest.path) {
            guard process.isRunning, ProcessInfo.processInfo.systemUptime < deadline else { throw CodeFailure("Fixture startup failed: " + (try String(contentsOf: output, encoding: .utf8))) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let ports = try JSONDecoder().decode([String: UInt16].self, from: Data(contentsOf: manifest))
        let mac = OrbitGoTransport(configuration: .init(stateDirectory: root.appendingPathComponent("mac")))
        let phone = OrbitGoTransport(configuration: .init(stateDirectory: root.appendingPathComponent("phone")))
        let macID = try mac.identity(), phoneID = try phone.identity()
        XCTAssertNotEqual(macID, phoneID)
        let key = P256.Signing.PrivateKey()
        let binding = CodeEndpointBinding(id: UUID().uuidString, accountPeerID: phoneID.description,
            deviceID: "physical-fixture", publicKey: key.publicKey.x963Representation)
        let hub = CodeReverseFlowHub(lookup: { id, peer in
            guard id == binding.id, peer == phoneID.description else { throw CodeFailure("Wrong TLS account") }; return binding
        })
        var control = CodeReverseControl(); control.bindingID = binding.id; control.generation = UUID().uuidString; control.provider = .syncthing
        let challenge = try await hub.begin(control, peer: phoneID.description)
        control.sessionID = try JSONDecoder().decode(CodeReverseChallenge.self, from: challenge).id
        control.signature = try Self.sign(challenge, key: key)
        let readiness = try await hub.finish(control, peer: phoneID.description)
        let listener = try await mac.relayListener(url: relay); defer { listener.close() }
        let broker = try CodeUnixAppleBroker(hub: hub, readiness: readiness); defer { broker.close() }
        let opened = RelayFlowCount(), active = RelayActiveFlows()
        try JSONSerialization.data(withJSONObject: ["path": broker.path, "token": broker.token])
            .write(to: root.appendingPathComponent("broker.json"), options: .atomic)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { accepts in
                    while !Task.isCancelled {
                        let accepted = try await listener.accept()
                        accepts.addTask {
                            guard accepted.device == phoneID else { accepted.stream.close(); throw CodeFailure("Relay replaced TLS peer identity") }
                            let routed = try await OrbitStreamDemultiplexer.classify(accepted.stream)
                            guard routed.installation else { routed.stream.close(); throw CodeFailure("Unexpected BEP stream") }
                            let stream = OrbitInstallStream(authenticatedStream: routed.stream)
                            let frame = try await CodeInstallFrame.read(from: stream)
                            guard frame.kind == .reverseProof else { stream.close(); throw CodeFailure("Missing phone key proof") }
                            try await hub.accept(JSONDecoder().decode(CodeReverseStreamProof.self, from: frame.payload), stream: stream, peer: accepted.device.description)
                            await opened.increment()
                        }
                    }
                }
            }
            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { flows in
                    var poll = CodeReverseControl(); poll.sessionID = readiness.id; poll.token = readiness.token; poll.generation = readiness.generation
                    while !Task.isCancelled {
                        poll.sequence += 1
                        for demand in try await hub.poll(poll, peer: phoneID.description) where active.claim(demand.id) {
                            flows.addTask {
                                defer { active.finish(demand.id) }
                                // The production runtime retries a demand after a failed dial,
                                // but never dials the same active demand twice.
                                do {
                                    let raw = try await phone.dial(OrbitPeerAddress(syncthingURL: relay.absoluteString)!, expecting: macID)
                                    let stream = OrbitInstallStream(authenticatedStream: raw)
                                    try await CodeReversePhoneFlow.serve(demand: demand, readiness: readiness,
                                        accountPeerID: phoneID.description, macPeerID: macID.description,
                                        identityKey: key.publicKey.x963Representation, sign: { try Self.sign($0, key: key) }, stream: stream,
                                        available: {}, openEndpoint: { service, port in
                                            guard service.permits(port: port),
                                                  port == (service == .lockdown ? 62078 : service == .afc ? 32100 : 32101),
                                                  let local = ports[service.rawValue] else { throw CodeFailure("Unexpected fixture endpoint") }
                                            return try Self.fixtureSocket(port: local)
                                        })
                                } catch {
                                    // Full helper closes and intentionally broken Apple replies end
                                    // streams with EOF; the Go assertions distinguish those outcomes.
                                }
                            }
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            group.addTask {
                while process.isRunning {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodeFailure("Combined Apple integration timed out") }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            do { try await group.next() }
            catch {
                broker.close(); listener.close(); await hub.revoke(); group.cancelAll()
                if process.isRunning { process.terminate() }
                // Listener-close/cancel errors are expected only after the monitor wins.
                throw error
            }
            broker.close(); listener.close(); await hub.revoke(); group.cancelAll()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CodeFailure("\(scenario): \((try? String(contentsOf: output, encoding: .utf8)) ?? "no Go output")")
        }
        let count = await opened.value
        XCTAssertEqual(count, scenario.hasPrefix("wrong-") ? 1 : 8, scenario)
        XCTAssertFalse(FileManager.default.fileExists(atPath: broker.directory.path))
    }

    private static func sign(_ data: Data, key: P256.Signing.PrivateKey) throws -> Data {
        try key.signature(for: Data("orbit-install-endpoint-v1\u{0}".utf8) + data).derRepresentation
    }
    private static func fixtureSocket(port: UInt16) throws -> CodeUnixStream {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodeFailure("Fixture socket failed") }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw CodeFailure("Fixture connect failed") }
        return CodeUnixStream(fd: fd)
    }
}
private actor RelayFlowCount {
    var value = 0
    func increment() { value += 1 }
}

private final class RelayActiveFlows: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()
    func claim(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.insert(id).inserted }
    func finish(_ id: String) { lock.lock(); defer { lock.unlock() }; ids.remove(id) }
}
