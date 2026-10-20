import Foundation
import Darwin
import OrbitCore
import OrbitWire
import OrbitTransport

public final class OrbitServer: @unchecked Sendable {
    public let host: OrbitHost
    public let transport: OrbitGoTransport
    public var approve: @Sendable (String) async -> Bool = { _ in false }
    private var dumbpipeID: DeviceID?
    private let root: URL
    private var listeners: [OrbitGoListener] = []
    public init(host: OrbitHost, root: URL) {
        self.root = root; self.host = host; transport = OrbitGoTransport(configuration: .init(stateDirectory: root.appendingPathComponent("Identity")))
    }
    public func start() async throws {
        let config = await host.configuration
        let listener = try await transport.listen(bindAddress: config.listen)
        listeners.append(listener)
        Task { await accept(listener) }
        if config.provider == "syncthing", let address = config.relay, let url = URL(string: address) {
            let relay = try await transport.relayListener(url: url); listeners.append(relay)
            Task { await self.accept(relay, pairingAllowed: false) }
        }
        if config.provider == "dumbpipe" {
            dumbpipeID = try await OrbitDumbpipe.shared.start(secretURL: root.appendingPathComponent("Identity/iroh.key"))
            Task { try? await OrbitDumbpipe.shared.accept { await self.serve($0, pairingAllowed: true) } }
        }
        try startLocalSocket()
        Task { while !Task.isCancelled { await host.tick(); try? await Task.sleep(for: .seconds(60)) } }
    }
    public func pairingCode() async throws -> String {
        let config = await host.configuration
        if let dumbpipeID { return OrbitPairingCode(deviceID: dumbpipeID, addresses: [.dumbpipe(endpoint: dumbpipeID.bytes.map { String(format: "%02x", $0) }.joined())]).text }
        let routes: [OrbitPeerAddress]
        if config.provider == "tailscale" || config.provider == "dumbpipe", let address = config.address, let route = OrbitPeerAddress(syncthingURL: address) { routes = [route] }
        else if config.provider == "syncthing", let address = config.relay, let route = OrbitPeerAddress(syncthingURL: address) { routes = [route] }
        else if let listener = listeners.first { routes = await listener.announcedAddresses.compactMap(OrbitPeerAddress.init(syncthingURL:)) }
        else { routes = [] }
        return OrbitPairingCode(deviceID: try transport.identity(), addresses: routes).text
    }
    private func accept(_ listener: OrbitGoListener, pairingAllowed: Bool = true) async {
        do {
            while true {
                let peer = try await listener.accept()
                Task { await self.serve(peer, pairingAllowed: pairingAllowed) }
            }
        } catch { /* The app owns listeners; closing one cancels its accept. */ }
    }
    private func serve(_ peer: OrbitAcceptedPeer, pairingAllowed: Bool) async {
        let stream = peer.stream
        let timer = Task { try? await Task.sleep(for: .seconds(190)); if !Task.isCancelled { stream.close() } }
        var transferred = false
        defer { timer.cancel(); if !transferred { stream.close() } }
        do {
            let trusted = await host.isTrusted(peer.device.description)
            if !trusted {
                guard pairingAllowed, await Date() < host.pairingUntil, await approve(peer.device.description) else { return }
                try await host.trust(peer.device.description)
            }
            let routed = try await OrbitStreamDemultiplexer.classify(stream)
            if routed.installation {
                guard let hub = await host.service.reverseFlows else { return }
                let install = OrbitInstallStream(authenticatedStream: routed.stream)
                let first = try await CodeInstallFrame.read(from: install)
                guard first.kind == .reverseProof, first.payload.count <= 4096 else { return }
                let proof = try JSONDecoder().decode(CodeReverseStreamProof.self, from: first.payload)
                try await hub.accept(proof, stream: install, peer: peer.device.description)
                transferred = true; timer.cancel()
                // Hub retains the stream until its authenticated flow finishes.
                return
            }
            guard try await routed.stream.read(exactly: 4) == OrbitRPC.magic else { return }
            let request = try await OrbitRPC.read(from: routed.stream)
            let response = await host.handle(request, peer: peer.device.description)
            try await OrbitRPC.write(response, to: routed.stream)
        } catch { /* Peer gets an EOF; no request contents go to global logs. */ }
    }
    private func startLocalSocket() throws {
        let path = root.appendingPathComponent("control.sock").path
        guard path.utf8.count < 104 else { throw CodeFailure("ORBIT_HOME is too long for a Unix socket.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BEPStreamError.posix(errno) }
        // A running instance owns the socket. Never unlink another server.
        if FileManager.default.fileExists(atPath: path) {
            var address = Self.address(path)
            if withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 {
                Darwin.close(fd); throw CodeFailure("Orbit Mac is already running.")
            }
            unlink(path)
        }
        var address = Self.address(path)
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0, listen(fd, 16) == 0 else { Darwin.close(fd); throw BEPStreamError.posix(errno) }
        chmod(path, 0o600)
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { break }
                let stream = FileDescriptorByteStream(fileDescriptor: client)
                Task {
                    let timer = Task { try? await Task.sleep(for: .seconds(190)); if !Task.isCancelled { stream.close() } }
                    defer { timer.cancel(); stream.close() }
                    do {
                        guard try await stream.read(exactly: 4) == OrbitRPC.magic else { return }
                        let response = await host.handle(try OrbitRPC.read(from: stream))
                        try await OrbitRPC.write(response, to: stream)
                    } catch { }
                }
            }
            Darwin.close(fd)
        }
    }
    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in path.withCString { source in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { strlcpy($0, source, 104) }
        } }
        return address
    }
}
