import Foundation
import CryptoKit
import OrbitCore
import Darwin

public final class CodeFiles: @unchecked Sendable {
    private let lock = NSLock()
    public init() {}
    public func open(_ path: String) throws -> CodeDocument {
        lock.lock(); defer { lock.unlock() }
        return try read(path).document
    }
    public func save(path: String, text: String, expected: String) throws -> (CodeDocument, Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !expected.isEmpty else { throw CodeFailure("A file version is required before saving.") }
        let url = try regularURL(path)
        var coordinationError: NSError?
        var result: Result<(CodeDocument, Bool), Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            result = Result {
                let current = try read(coordinated.path)
                guard let bytes = encode(text, as: current.document.encoding), bytes.count <= CodeWire.maxFileBytes else {
                    throw CodeFailure("The file is too large or cannot be represented in its original encoding.")
                }
                if bytes == current.bytes { return (current.document, false) } // retry after lost acknowledgement
                guard current.document.version == expected else { return (current.document, true) }
                let temporary = coordinated.deletingLastPathComponent().appendingPathComponent(".orbit-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try bytes.write(to: temporary, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: current.permissions], ofItemAtPath: temporary.path)
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.synchronize(); try handle.close()
                let beforeReplace = try read(coordinated.path)
                guard beforeReplace.document.version == expected else { return (beforeReplace.document, true) }
                _ = try FileManager.default.replaceItemAt(coordinated, withItemAt: temporary)
                let directory = Darwin.open(coordinated.deletingLastPathComponent().path, O_RDONLY)
                if directory >= 0 { _ = fsync(directory); close(directory) }
                return (try read(coordinated.path).document, false)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CodeFailure("macOS could not coordinate this save.") }
        return try result.get()
    }
    private func regularURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 16_384 else { throw CodeFailure("Choose an absolute Mac file path.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let canonical = url.resolvingSymlinksInPath()
        // Opening a link returns its target path. Saving never follows a newly substituted link.
        guard canonical.path == url.path else { throw CodeFailure("Open the original file instead of a symbolic link.") }
        return url
    }
    private func read(_ path: String) throws -> (document: CodeDocument, bytes: Data, permissions: NSNumber) {
        let url = try regularURL(path)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CodeFailure("Cannot open this file. Check Mac permissions and that the file still exists.") }
        defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size <= CodeWire.maxFileBytes else { throw CodeFailure("Open a text source file up to 2 MB.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try handle.readToEnd() ?? Data()
        var after = stat(); guard fstat(fd, &after) == 0, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw CodeFailure("The file changed while being read. Try again.") }
        let encoding: String; let text: String?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { encoding = "utf8bom"; text = String(data: bytes.dropFirst(3), encoding: .utf8) }
        else if bytes.starts(with: [0xFF, 0xFE]) { encoding = "utf16le"; text = String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian) }
        else if bytes.starts(with: [0xFE, 0xFF]) { encoding = "utf16be"; text = String(data: bytes.dropFirst(2), encoding: .utf16BigEndian) }
        else { encoding = "utf8"; text = String(data: bytes, encoding: .utf8) }
        guard let text, !text.contains("\u{0}") else { throw CodeFailure("This is not a supported UTF-8 or UTF-16 text file.") }
        let version = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (CodeDocument(path: url.path, text: text, version: version, encoding: encoding), bytes, NSNumber(value: before.st_mode & 0o777))
    }
    private func encode(_ text: String, as encoding: String) -> Data? {
        switch encoding {
        case "utf8bom": return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case "utf16le": return text.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        case "utf16be": return text.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        default: return text.data(using: .utf8)
        }
    }
}
