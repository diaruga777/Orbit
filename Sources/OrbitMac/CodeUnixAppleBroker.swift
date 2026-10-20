import Foundation
import Darwin
import OrbitCore

/// One private, job-token Unix broker for the pinned Apple helper. It exposes
/// neither a TCP listener nor a Code RPC for caller-selected hosts or ports.
public final class CodeUnixAppleBroker: @unchecked Sendable {
    public let directory: URL
    public var path: String { directory.appendingPathComponent("b.sock").path }
    public let token = UUID().uuidString + UUID().uuidString
    private let hub: CodeReverseFlowHub
    private let readiness: CodeReverseReadiness
    private let state: UnixBrokerState
    private let lock = NSLock()
    private var sockets: [UUID: CodeUnixStream] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var ports: [CodeAppleStreamService: Set<UInt16>] = [:]
    private var opened = 0
    private var ended = false
    private var listener: Task<Void, Never>?
    public init(hub: CodeReverseFlowHub, readiness: CodeReverseReadiness) throws {
        self.hub = hub; self.readiness = readiness
        directory = URL(fileURLWithPath: "/tmp/lc-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); throw CodeFailure("Couldn’t create the private Apple broker.") }
        state = UnixBrokerState(fd: fd)
        do {
            let text = directory.appendingPathComponent("b.sock").path
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let encoded = Array(text.utf8) + [0]
            guard encoded.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodeFailure("Apple broker path is too long.") }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: encoded) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0, Darwin.listen(fd, 8) == 0 else { throw CodeFailure("Couldn’t bind the private Apple broker.") }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: text)
        } catch { state.close(); try? FileManager.default.removeItem(at: directory); throw error }
        let state = state
        listener = Task.detached { [weak self] in
            while !state.closed && !Task.isCancelled {
                var descriptor = pollfd(fd: state.fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 250)
                guard !state.closed else { return }
                if ready > 0 {
                    let accepted = Darwin.accept(state.fd, nil, nil)
                    if accepted >= 0 { if let self { self.accepted(accepted) } else { Darwin.close(accepted) } }
                } else if ready < 0 && errno != EINTR { return }
            }
        }
    }
    public func close() {
        let old = lock.withCriticalScope { () -> ([CodeUnixStream], [Task<Void, Never>])? in
            guard !ended else { return nil }; ended = true
            let old = (Array(sockets.values), Array(tasks.values)); sockets.removeAll(); tasks.removeAll(); return old
        }
        guard let old else { return }
        state.close(); listener?.cancel(); old.1.forEach { $0.cancel() }; old.0.forEach { $0.close() }
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { close() }
    private func accepted(_ fd: Int32) {
        let socket = CodeUnixStream(fd: fd), id = UUID()
        let valid = lock.withCriticalScope { () -> Bool in
            guard !ended, sockets.count < 8, opened < 32 else { return false }
            opened += 1; sockets[id] = socket; return true
        }
        guard valid else { socket.close(); return }
        let task = Task<Void, Never> { [weak self] in guard let self else { return }; await self.serve(socket, id: id) }
        lock.withCriticalScope { if ended || sockets[id] == nil { task.cancel() } else { tasks[id] = task } }
    }
    private struct Request: Decodable { var version: Int; var token: String; var service: CodeAppleStreamService; var port: UInt16; var fullCloseOnEOF: Bool? }
    private func serve(_ socket: CodeUnixStream, id: UUID) async {
        defer { socket.close(); lock.withCriticalScope { sockets[id] = nil; tasks[id] = nil } }
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { socket.close() } }
        defer { timeout.cancel() }
        do {
            let header = try await socket.read(exactly: 8)
            let size = header[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard Array(header.prefix(4)) == [76, 67, 65, 49], size > 0, size <= 1024 else { throw CodeFailure("Invalid Apple broker frame.") }
            let request = try await JSONDecoder().decode(Request.self, from: socket.read(exactly: Int(size)))
            let valid = lock.withCriticalScope { () -> Bool in
                guard !ended, request.version == 1, request.token == token, request.service.permits(port: request.port) else { return false }
                var known = ports[request.service] ?? []
                guard known.contains(request.port) || known.count < (request.service == .lockdown ? 1 : 4) else { return false }
                known.insert(request.port); ports[request.service] = known; return true
            }
            guard valid else { throw CodeFailure("Apple broker authorization rejected.") }
            timeout.cancel()
            let remote = try await hub.open(readiness: readiness, service: request.service, port: request.port)
            defer { remote.close() }
            try await withTaskCancellationHandler {
                try Task.checkCancellation(); try await socket.write(Data([1]))
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while let bytes = try await socket.read(maximum: CodeInstallFrame.maximumPayload) { try await remote.write(bytes) }
                        if request.fullCloseOnEOF == true { remote.close() }
                        else { try await remote.halfClose() }
                    }
                    group.addTask {
                        while let bytes = try await remote.read(maximum: CodeInstallFrame.maximumPayload) { try await socket.write(bytes) }
                        try await socket.halfClose()
                    }
                    do { _ = try await group.next(); _ = try await group.next(); group.cancelAll() }
                    catch { socket.close(); remote.close(); group.cancelAll(); throw error }
                }
            } onCancel: { socket.close(); remote.close() }
        } catch { socket.close() }
    }
}
private final class UnixBrokerState: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock(); private var ended = false
    var closed: Bool { lock.withCriticalScope { ended } }
    init(fd: Int32) { self.fd = fd }
    func close() { lock.withCriticalScope { ended = true }; _ = shutdown(fd, SHUT_RDWR) }
    deinit { Darwin.close(fd) }
}

/// Independent serial read/write queues, bounded chunks, no descriptor reuse
/// while I/O is pending. Shutdown wakes cancellation before deinit closes the fd.
final class CodeUnixStream: CodeDeviceFlowSocket, CodeInstallStream, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock(); private var ended = false
    private let reads = DispatchQueue(label: "Code.AppleUnix.read"), writes = DispatchQueue(label: "Code.AppleUnix.write")
    init(fd: Int32) {
        self.fd = fd; _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    private func wait(_ event: Int16) throws {
        while true {
            guard !lock.withCriticalScope({ ended }) else { throw CancellationError() }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 250)
            if ready > 0 { return }
            if ready < 0 && errno != EINTR { throw CodeFailure("Apple broker socket failed.") }
        }
    }
    func read(exactly count: Int) async throws -> Data {
        guard count >= 0, count <= 65536 else { throw CodeFailure("Apple broker read exceeds its limit.") }
        var result = Data()
        while result.count < count {
            guard let next = try await read(maximum: count - result.count) else { throw CodeFailure("Apple broker disconnected.") }; result.append(next)
        }
        return result
    }
    func read(maximum count: Int) async throws -> Data? {
        guard (1...65536).contains(count) else { throw CodeFailure("Apple broker read exceeds its limit.") }
        return try await withCheckedThrowingContinuation { continuation in
            reads.async {
                do {
                    var bytes = [UInt8](repeating: 0, count: count)
                    while true {
                        try self.wait(Int16(POLLIN))
                        let amount = Darwin.read(self.fd, &bytes, count)
                        if amount == 0 { continuation.resume(returning: nil); return }
                        if amount > 0 { continuation.resume(returning: Data(bytes.prefix(amount))); return }
                        if ![EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { throw CodeFailure("Apple broker read failed.") }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func write(_ data: Data) async throws {
        guard data.count <= 65536 else { throw CodeFailure("Apple broker write exceeds its limit.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async {
                do {
                    var offset = 0
                    while offset < data.count {
                        try self.wait(Int16(POLLOUT))
                        let amount = data.withUnsafeBytes { Darwin.write(self.fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                        if amount > 0 { offset += amount }
                        else if amount == 0 || ![EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { throw CodeFailure("Apple broker write failed.") }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func halfClose() async throws { _ = shutdown(fd, SHUT_WR) }
    func close() { lock.withCriticalScope { ended = true }; _ = shutdown(fd, SHUT_RDWR) }
    deinit { close(); Darwin.close(fd) }
}
