import Foundation
import OrbitCore
import OrbitWire

/// One bounded JSON exchange per authenticated stream. No source, token or pairing
/// record goes into discovery. ORBT is distinct from retained-install LCDF frames.
public enum OrbitRPC {
    public static let magic = Data("ORBT".utf8)
    public static func write(_ value: Data, to stream: any BEPByteStream) async throws {
        guard value.count <= CodeWire.maxPayloadBytes else { throw CodeFailure("Message too large.") }
        var size = UInt32(value.count).bigEndian
        try await stream.write(withUnsafeBytes(of: &size) { Data($0) } + value)
    }
    public static func read(from stream: any BEPByteStream) async throws -> Data {
        let header = try await stream.read(exactly: 4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= CodeWire.maxPayloadBytes else { throw CodeFailure("Invalid message size.") }
        return try await stream.read(exactly: Int(size))
    }
    public static func exchange(_ value: Data, stream: any BEPByteStream, timeout: TimeInterval = 180) async throws -> Data {
        let timer = Task { try? await Task.sleep(for: .seconds(timeout)); if !Task.isCancelled { stream.close() } }
        defer { timer.cancel(); stream.close() }
        return try await withTaskCancellationHandler {
            try await stream.write(magic); try await write(value, to: stream)
            return try await read(from: stream)
        } onCancel: { stream.close() }
    }
}
