import Foundation

/// An authenticated, plaintext, ordered byte stream to one peer.
///
/// The transport layer (`OrbitNet`, over the Go TLS engine) produces
/// these; `BEPConnection` consumes them. Tests use `PipeByteStream`.
public protocol BEPByteStream: AnyObject, Sendable {
    /// Reads exactly `count` bytes. Throws `BEPStreamError.closed` at EOF.
    func read(exactly count: Int) async throws -> Data
    /// Writes all of `data`.
    func write(_ data: Data) async throws
    /// Closes both directions. Idempotent. Wakes any blocked read or write.
    func close()
}

public enum BEPStreamError: Error, Equatable, LocalizedError {
    case closed
    case posix(Int32)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .closed: return "The Mac disconnected while sending the file. Keep Orbit open on the Mac and try again."
        case .timedOut: return "The Mac stopped responding while sending the file. Check the connection and try again."
        case .posix: return "The connection to the Mac failed while sending the file. Try again."
        }
    }
}

/// A byte stream over a socket-like file descriptor. Reads and writes run on
/// their own dispatch queues and poll in 250 ms ticks so `close()` from
/// another thread wakes a blocked call.
public final class FileDescriptorByteStream: BEPByteStream, @unchecked Sendable {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "orbit.bep.stream.read")
    private let writeQueue = DispatchQueue(label: "orbit.bep.stream.write")
    private let stateLock = NSLock()
    private var closed = false

    public init(fileDescriptor: Int32) {
        fd = fileDescriptor
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    deinit {
        close()
        Darwin.close(fd)
    }

    private var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    public func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
                do {
                    continuation.resume(returning: try self.blockingRead(count))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                do {
                    try self.blockingWrite(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() {
        stateLock.lock()
        let wasClosed = closed
        closed = true
        stateLock.unlock()
        if !wasClosed {
            shutdown(fd, SHUT_RDWR)
        }
    }

    private func wait(for events: Int16) throws {
        while true {
            if isClosed { throw BEPStreamError.closed }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&pfd, 1, 250)
            if result > 0 { return }
            if result < 0 {
                let code = errno
                if code == EINTR { continue }
                throw BEPStreamError.posix(code)
            }
        }
    }

    private func blockingRead(_ count: Int) throws -> Data {
        var output = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: min(count, 1 << 16))
        while output.count < count {
            try wait(for: Int16(POLLIN))
            let wanted = min(buffer.count, count - output.count)
            let n = Darwin.read(fd, &buffer, wanted)
            if n == 0 { throw BEPStreamError.closed }
            if n < 0 {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { continue }
                throw BEPStreamError.posix(code)
            }
            output.append(buffer, count: n)
        }
        return output
    }

    private func blockingWrite(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                try wait(for: Int16(POLLOUT))
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    let code = errno
                    if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { continue }
                    if code == EPIPE || code == ECONNRESET { throw BEPStreamError.closed }
                    throw BEPStreamError.posix(code)
                }
                offset += n
            }
        }
    }
}

/// Two in-memory streams joined end to end, for tests and in-process peers.
public final class PipeByteStream: BEPByteStream, @unchecked Sendable {
    private final class Channel: @unchecked Sendable {
        typealias Waiter = CheckedContinuation<Result<Data?, Error>, Never>
        private let lock = NSLock()
        private var buffer = Data()
        private var closed = false
        private var waiters: [Waiter] = []

        func append(_ data: Data) throws {
            lock.lock()
            if closed { lock.unlock(); throw BEPStreamError.closed }
            buffer.append(data)
            let resume = waiters
            waiters.removeAll()
            lock.unlock()
            resume.forEach { $0.resume(returning: .success(nil)) }
        }

        /// Under the lock: hands out `count` bytes, reports closure, or parks
        /// the waiter. A parked waiter is woken with `nil` to try again.
        private func takeOrPark(_ count: Int, _ waiter: Waiter) {
            lock.lock()
            if buffer.count >= count {
                let out = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                lock.unlock()
                waiter.resume(returning: .success(out))
            } else if closed {
                lock.unlock()
                waiter.resume(returning: .failure(BEPStreamError.closed))
            } else {
                waiters.append(waiter)
                lock.unlock()
            }
        }

        func take(_ count: Int) async throws -> Data {
            while true {
                let result = await withCheckedContinuation { (waiter: Waiter) in
                    takeOrPark(count, waiter)
                }
                switch result {
                case .success(let data?): return data
                case .success(nil): continue
                case .failure(let error): throw error
                }
            }
        }

        func close() {
            lock.lock()
            closed = true
            let resume = waiters
            waiters.removeAll()
            lock.unlock()
            resume.forEach { $0.resume(returning: .success(nil)) }
        }
    }

    private let incoming: Channel
    private let outgoing: Channel

    private init(incoming: Channel, outgoing: Channel) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    /// Returns two connected ends.
    public static func pair() -> (PipeByteStream, PipeByteStream) {
        let a = Channel()
        let b = Channel()
        return (PipeByteStream(incoming: a, outgoing: b), PipeByteStream(incoming: b, outgoing: a))
    }

    public func read(exactly count: Int) async throws -> Data {
        try await incoming.take(count)
    }

    public func write(_ data: Data) async throws {
        try outgoing.append(data)
    }

    public func close() {
        incoming.close()
        outgoing.close()
    }
}
