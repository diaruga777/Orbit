import Foundation
import OrbitWire

/// A fresh authenticated TLS connection is either BEP or an LCDF installation
/// stream. Peek only its magic and replay those bytes to the selected parser.
/// Existing BEP streams are never reclassified or used for Apple byte traffic.
public enum OrbitStreamDemultiplexer {
    public static func classify(_ stream: any BEPByteStream) async throws -> (installation: Bool, stream: any BEPByteStream) {
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { stream.close() } }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            let prefix = try await stream.read(exactly: 4)
            return (prefix == Data([0x4c, 0x43, 0x44, 0x46]), PrefixStream(prefix: prefix, stream: stream))
        } onCancel: { stream.close() }
    }
}
private final class PrefixStream: BEPByteStream, @unchecked Sendable {
    private let reader: PrefixReader
    private let stream: any BEPByteStream
    init(prefix: Data, stream: any BEPByteStream) { self.stream = stream; reader = PrefixReader(prefix: prefix, stream: stream) }
    func read(exactly count: Int) async throws -> Data { try await reader.read(count) }
    func write(_ data: Data) async throws { try await stream.write(data) }
    func close() { stream.close() }
}
private actor PrefixReader {
    var prefix: Data
    let stream: any BEPByteStream
    init(prefix: Data, stream: any BEPByteStream) { self.prefix = prefix; self.stream = stream }
    func read(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw BEPStreamError.closed }
        let portion = Data(prefix.prefix(count)); prefix.removeFirst(portion.count)
        if portion.count == count { return portion }
        return try await portion + stream.read(exactly: count - portion.count)
    }
}
