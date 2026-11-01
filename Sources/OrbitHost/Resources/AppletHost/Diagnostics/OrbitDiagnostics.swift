import Foundation

public struct OrbitDiagnosticEvent: Codable, Sendable, Equatable {
    public var id: String
    public var time: Date
    public var session: String
    public var category: String
    public var name: String
    public var fields: [String: String]
    /// Monotonic within a writer session; optional for older journals.
    public var sequence: UInt64?
}

/// Private, bounded JSON-lines journals. Callers supply event metadata only,
/// never text-field contents, source, RPC bodies or installer transcripts.
public final class OrbitDiagnostics: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: OrbitDiagnostics] = [:]
    public static let shared = store(directory: defaultDirectory)
    public static func store(directory: URL) -> OrbitDiagnostics {
        registryLock.lock(); defer { registryLock.unlock() }
        let key = directory.standardizedFileURL.path
        if let store = registry[key] { return store }
        let store = OrbitDiagnostics(directory: directory)
        registry[key] = store
        return store
    }
    public static var defaultDirectory: URL {
        #if os(macOS)
        let root = ((Bundle.main.object(forInfoDictionaryKey: "OrbitStateRoot") as? String) ?? ProcessInfo.processInfo.environment["ORBIT_HOME"]).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orbit")
        #else
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbit")
        #endif
        return root.appendingPathComponent("Logs")
    }
    public let directory: URL
    private let lock = NSRecursiveLock()
    private var nextSequence: UInt64 = 0
    private let session = UUID().uuidString
    private let limit: Int
    private let count: Int
    private var knownIDs: Set<String>?
    public init(directory: URL, fileBytes: Int = 1024 * 1024, fileCount: Int = 4) {
        self.directory = directory; limit = max(4096, fileBytes); count = max(2, fileCount)
    }
    public func record(_ category: String, _ name: String, _ fields: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        nextSequence += 1
        let event = OrbitDiagnosticEvent(id: UUID().uuidString, time: Date(), session: session,
            category: category, name: name, fields: fields, sequence: nextSequence)
        do { try append([event]) } catch { /* Diagnostics must never stop a user action. */ }
    }
    public func error(_ category: String, _ name: String, _ error: Error, _ fields: [String: String] = [:]) {
        var fields = fields
        let value = error as NSError
        fields["errorDomain"] = value.domain; fields["errorCode"] = String(value.code)
        fields["error"] = error.localizedDescription
        record(category, name, fields)
    }
    public func events(after cursor: String? = nil, maximum: Int = 128) -> [OrbitDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        let all = readLocked()
        let start = cursor.flatMap { id in all.lastIndex(where: { $0.id == id }).map { $0 + 1 } } ?? 0
        return Array(all.dropFirst(start).prefix(max(0, min(128, maximum))))
    }
    public func recent(maximum: Int = 100) -> [OrbitDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return Array(readLocked().suffix(max(0, min(500, maximum))))
    }
    /// Also sanitizes imported phone entries; remote metadata is untrusted.
    /// IDs make retry after a lost acknowledgement idempotent, including restart.
    public func append(_ events: [OrbitDiagnosticEvent]) throws {
        guard events.count <= 128 else { throw OrbitDiagnosticFailure("Too many diagnostic events.") }
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var ids = knownIDs ?? Set(readLocked().map(\.id))
        defer { knownIDs = ids }
        for event in events where !ids.contains(event.id) {
            guard UUID(uuidString: event.id) != nil, UUID(uuidString: event.session) != nil,
                  event.time.timeIntervalSince1970.isFinite else { throw OrbitDiagnosticFailure("Invalid diagnostic event.") }
            var safe = event
            safe.category = Self.clean(event.category); safe.name = Self.clean(event.name)
            safe.fields = [:]
            for (key, value) in event.fields.sorted(by: { $0.key < $1.key }).prefix(12) {
                safe.fields[String(key.prefix(64))] = Self.privateKey(key) ? "[redacted]" : Self.clean(value)
            }
            let data = try JSONEncoder().encode(safe) + Data([10])
            guard data.count <= 16384 else { throw OrbitDiagnosticFailure("Diagnostic event too large.") }
            let file = url(0)
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            if size + data.count > limit {
                ids = Set(readLocked().map(\.id))
                try? fm.removeItem(at: url(count - 1))
                for index in stride(from: count - 2, through: 0, by: -1) where fm.fileExists(atPath: url(index).path) {
                    try fm.moveItem(at: url(index), to: url(index + 1))
                }
            }
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
            ids.insert(event.id)
        }
    }
    private func url(_ index: Int) -> URL { directory.appendingPathComponent(index == 0 ? "events.jsonl" : "events.\(index).jsonl") }
    private func readLocked() -> [OrbitDiagnosticEvent] {
        (0..<count).reversed().flatMap { index -> [OrbitDiagnosticEvent] in
            guard let data = try? Data(contentsOf: url(index)), data.count <= limit + 16384 else { return [] }
            return data.split(separator: 10).compactMap { try? JSONDecoder().decode(OrbitDiagnosticEvent.self, from: Data($0)) }
        }
    }
    private static func privateKey(_ key: String) -> Bool {
        ["password", "token", "secret", "authorization", "cookie", "source", "text", "pairing", "certificate"].contains { key.lowercased().contains($0) }
    }
    public static func clean(_ value: String) -> String {
        var text = String(value.prefix(1200))
        // Errors may contain paths, account names or credential-bearing URLs.
        for pattern in [#"(?s)-----BEGIN.*"#, #"(?i)(?:https?|orbit|file)://[^\s]+"#,
                        #"(?i)(?:bearer\s+|(?:password|token|secret|cookie|authorization)\s*[:=]\s*)[^\s,;]+"#,
                        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                        #"/(?:Users|private|var)/[^\s]+"#, #"[A-Za-z0-9_+/=-]{64,}"#] {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(text.prefix(600))
    }
}

private struct OrbitDiagnosticFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
