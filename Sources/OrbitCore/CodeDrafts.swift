import Foundation
import CryptoKit

/// Drafts belong to a Mac identity as well as a path. Pairing a different Mac
/// must never turn yesterday's draft into a write to an unrelated computer.
public struct CodeDraft: Codable, Sendable {
    public var base: CodeDocument
    public var text: String
    public var selection: Int
    public var modified: Bool { text != base.text }
    public init(base: CodeDocument, text: String? = nil, selection: Int = 0) {
        self.base = base; self.text = text ?? base.text; self.selection = selection
    }
}
public final class CodeDraftStore: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func url(peer: String, path: String) -> URL {
        let hash = SHA256.hash(data: Data((peer + "\u{0}" + path).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash + ".json")
    }
    public func load(peer: String, path: String) throws -> CodeDraft? {
        lock.lock(); defer { lock.unlock() }
        let file = url(peer: peer, path: path)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(CodeDraft.self, from: Data(contentsOf: file))
    }
    public func save(_ draft: CodeDraft, peer: String) throws {
        lock.lock(); defer { lock.unlock() }
        let file = url(peer: peer, path: draft.base.path)
        try JSONEncoder().encode(draft).write(to: file, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        #endif
    }
}
