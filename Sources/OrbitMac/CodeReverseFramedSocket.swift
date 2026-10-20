import Foundation
import OrbitCore

/// Mac half of a single opaque Apple stream. Renewals arrive on this stream,
/// not via another device sharing the account. EOF preserves half-close.
final class CodeReverseFramedSocket: CodeDeviceFlowSocket, @unchecked Sendable {
    private let stream: any CodeInstallStream
    private let reader: ReverseFrameReader
    private let state: ReverseFrameState
    private var watchdog: Task<Void, Never>?
    init(stream: any CodeInstallStream, uptime: @escaping @Sendable () -> TimeInterval,
         released: @escaping @Sendable () -> Void, transferred: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.stream = stream
        let state = ReverseFrameState(uptime: uptime, close: { bytes in stream.close(); released(); transferred(bytes) }); self.state = state
        reader = ReverseFrameReader(stream: stream, state: state)
        watchdog = Task { [state] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)); try state.check() }
                catch { state.close(); return }
            }
        }
    }
    func read(maximum: Int) async throws -> Data? {
        do { return try await reader.read(maximum: maximum) } catch { close(); throw error }
    }
    func write(_ data: Data) async throws {
        try state.consume(data.count)
        try await stream.write(CodeInstallFrame(.data, payload: data).encoded())
    }
    func halfClose() async throws { try state.check(); try await stream.write(CodeInstallFrame(.halfClose).encoded()) }
    func close() { watchdog?.cancel(); state.close() }
    deinit { close() }
}
private actor ReverseFrameReader {
    let stream: any CodeInstallStream
    let state: ReverseFrameState
    var buffer = Data()
    var eof = false
    init(stream: any CodeInstallStream, state: ReverseFrameState) { self.stream = stream; self.state = state }
    func read(maximum: Int) async throws -> Data? {
        guard (1...CodeInstallFrame.maximumPayload).contains(maximum) else { throw CodeFailure("Invalid Apple stream read size.") }
        try state.check()
        while buffer.isEmpty && !eof {
            let frame = try await CodeInstallFrame.read(from: stream)
            switch frame.kind {
            case .data: try state.consume(frame.payload.count); buffer = frame.payload
            case .renew:
                let renewal = try JSONDecoder().decode(CodeReverseRenewal.self, from: frame.payload)
                try state.renew(renewal.sequence)
            case .halfClose: eof = true
            case .close: state.close(); eof = true
            default: state.close(); throw CodeFailure("Unexpected Apple stream frame.")
            }
        }
        if buffer.isEmpty { return nil }
        let result = Data(buffer.prefix(maximum)); buffer.removeFirst(result.count); return result
    }
}
private final class ReverseFrameState: @unchecked Sendable {
    private let lock = NSLock()
    private let uptime: @Sendable () -> TimeInterval
    private let closed: @Sendable (Int64) -> Void
    private var ended = false
    private var deadline: TimeInterval
    private let hard: TimeInterval
    private var sequence: UInt64 = 0
    private var bytes: Int64 = 0
    init(uptime: @escaping @Sendable () -> TimeInterval, close: @escaping @Sendable (Int64) -> Void) {
        self.uptime = uptime; closed = close; deadline = uptime() + 60; hard = uptime() + 900
    }
    func check() throws { try lock.withCriticalScope { try checkLocked() } }
    private func checkLocked() throws { guard !ended, uptime() < deadline, uptime() < hard else { throw CodeFailure("Apple stream lease expired.") } }
    func consume(_ count: Int) throws {
        try lock.withCriticalScope {
            try checkLocked()
            guard count >= 0, count <= CodeInstallFrame.maximumPayload, bytes <= 8 * 1024 * 1024 * 1024 - Int64(count) else { throw CodeFailure("Apple stream byte limit reached.") }
            bytes += Int64(count)
        }
    }
    func renew(_ value: UInt64) throws {
        try lock.withCriticalScope {
            try checkLocked(); guard value > sequence else { throw CodeFailure("Replayed Apple stream renewal.") }
            sequence = value; deadline = min(hard, uptime() + 60)
        }
    }
    func close() {
        let total = lock.withCriticalScope { () -> Int64? in if ended { return nil }; ended = true; return bytes }
        if let total { closed(total) }
    }
}
