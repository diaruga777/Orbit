import Foundation
import Network
import Darwin
import OrbitCore
import OrbitWire

/// Dedicated authenticated stream adapter. The caller opens a fresh Go/TLS
/// stream (direct or explicit relay); no frames enter a live BEP connection.
public final class OrbitInstallStream: CodeInstallStream, @unchecked Sendable {
    private let stream: any BEPByteStream
    public init(authenticatedStream: any BEPByteStream) { stream = authenticatedStream }
    public func read(exactly count: Int) async throws -> Data {
        guard (0...CodeInstallFrame.maximumPayload).contains(count) else { throw CodeFailure("Device flow read exceeds its limit.") }
        return try await stream.read(exactly: count)
    }
    public func write(_ data: Data) async throws {
        guard data.count <= CodeInstallFrame.maximumPayload + 10 else { throw CodeFailure("Device flow write exceeds its limit.") }
        try await stream.write(data)
    }
    public func close() { stream.close() }
}

/// This registry must be populated from the current phone's observed Apple
/// services after endpoint enrollment. It is not a general host/port dialer.
public struct OrbitLocalAppleService: Sendable {
    public let id: String
    public let numericHost: String
    public let port: UInt16
    public init(id: String, numericHost: String, port: UInt16) {
        self.id = id; self.numericHost = numericHost; self.port = port
    }
}
public actor OrbitLocalAppleServices {
    private var endpoints: [String: OrbitLocalAppleService] = [:]
    public init() {}
    public func replace(verifiedEndpoints: [OrbitLocalAppleService]) throws {
        guard verifiedEndpoints.count <= 16, Set(verifiedEndpoints.map(\.id)).count == verifiedEndpoints.count,
              verifiedEndpoints.allSatisfy({ !$0.id.isEmpty && $0.port > 0 && Self.owns($0.numericHost) }) else { throw CodeFailure("A device service does not belong to this phone.") }
        endpoints = Dictionary(uniqueKeysWithValues: verifiedEndpoints.map { ($0.id, $0) })
    }
    public func clear() { endpoints.removeAll() }
    public func open(_ id: String) async throws -> any CodeDeviceFlowSocket {
        guard let endpoint = endpoints[id], Self.owns(endpoint.numericHost) else { throw CodeFailure("The phone’s development service changed. Reconnect before installing.") }
        return try await OrbitDeviceSocket.connect(host: endpoint.numericHost, port: endpoint.port)
    }
    /// Ports come only from the authenticated, enrolled Mac Apple-helper
    /// demand. Resolve no host from the wire; connect back to this Wi-Fi device.
    public static func openVerifiedService(_ service: CodeAppleStreamService, port: UInt16, interfaces: Set<String>) async throws -> any CodeDeviceFlowSocket {
        guard service.permits(port: port) else { throw CodeFailure("Unexpected Apple service port.") }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { throw CodeFailure("The phone’s Wi-Fi address is unavailable.") }; defer { freeifaddrs(list) }
        var current = list, hosts: [String] = []
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard interfaces.contains(String(cString: entry.pointee.ifa_name)), entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr, [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &numeric, socklen_t(numeric.count), nil, 0, NI_NUMERICHOST) == 0 {
                let host = String(cString: numeric)
                if !hosts.contains(host) { if address.pointee.sa_family == UInt8(AF_INET) { hosts.insert(host, at: 0) } else { hosts.append(host) } }
            }
        }
        for host in hosts.prefix(2) where owns(host) {
            try Task.checkCancellation()
            if let socket = try? await OrbitDeviceSocket.connect(host: host, port: port) { return socket }
        }
        throw CodeFailure("This phone’s Apple development service is unavailable.")
    }
    private static func owns(_ host: String) -> Bool {
        // Only assigned numeric addresses; never resolve DNS or use a claimed
        // Tailscale prefix as proof of device identity or Wi-Fi association.
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }; defer { freeifaddrs(list) }
        var item = list
        while let entry = item {
            defer { item = entry.pointee.ifa_next }
            guard entry.pointee.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.pointee.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &numeric, socklen_t(numeric.count), nil, 0, NI_NUMERICHOST) == 0,
               String(cString: numeric) == host { return true }
        }
        return false
    }
}
private final class OrbitDeviceSocket: CodeDeviceFlowSocket, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Orbit.Code.DeviceSocket")
    private init(host: String, port: UInt16) { connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
    static func connect(host: String, port: UInt16) async throws -> OrbitDeviceSocket {
        let socket = OrbitDeviceSocket(host: host, port: port)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion = DeviceSocketCompletion()
                socket.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard completion.claim() else { return }; socket.connection.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed, .cancelled:
                        guard completion.claim() else { return }; socket.connection.stateUpdateHandler = nil; socket.close()
                        continuation.resume(throwing: CodeFailure("The phone’s development service is unavailable."))
                    default: break
                    }
                }
                socket.connection.start(queue: socket.queue)
                socket.queue.asyncAfter(deadline: .now() + 5) {
                    guard completion.claim() else { return }; socket.connection.stateUpdateHandler = nil; socket.close()
                    continuation.resume(throwing: CodeFailure("The phone’s development service timed out."))
                }
            }
        } onCancel: { socket.close() }
        try Task.checkCancellation(); return socket
    }
    func read(maximum: Int) async throws -> Data? {
        guard (1...CodeInstallFrame.maximumPayload).contains(maximum) else { throw CodeFailure("Invalid device flow read size.") }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: nil) }
                else { continuation.resume(throwing: CodeFailure("The phone’s development service stopped responding.")) }
            }
        }
    }
    func write(_ data: Data) async throws {
        guard data.count <= CodeInstallFrame.maximumPayload else { throw CodeFailure("Device flow write exceeds its limit.") }
        try await send(data, complete: false)
    }
    func halfClose() async throws { try await send(nil, complete: true) }
    private func send(_ data: Data?, complete: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: complete ? .finalMessage : .defaultMessage, isComplete: complete, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func close() { connection.cancel() }
    deinit { connection.cancel() }
}
private final class DeviceSocketCompletion: @unchecked Sendable {
    private let lock = NSLock(); private var completed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !completed else { return false }; completed = true; return true }
}
