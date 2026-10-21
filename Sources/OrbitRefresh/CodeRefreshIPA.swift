import Foundation
import SideSign
import OrbitCore

/// Validate every entry before extracting any file. The upstream convenience
/// extractor accepts arbitrary ZIP paths, so imported IPAs use this boundary.
enum CodeRefreshIPA {
    static func extract(_ ipa: URL, to root: URL) throws -> URL {
        let archive = try Archive.Reader.open(at: ipa)
        let entries = try archive.entries()
        guard !entries.isEmpty, entries.count <= 100_000 else { throw CodeFailure("This build has too many files.") }
        var total: Int64 = 0, names = Set<String>(), apps = Set<String>()
        for entry in entries {
            let parts = entry.filename.split(separator: "/", omittingEmptySubsequences: true)
            let relative = parts.joined(separator: "/")
            guard !entry.filename.hasPrefix("/"), !entry.filename.contains("\\"),
                  !parts.contains(".."), !parts.contains("."),
                  names.insert(relative).inserted,
                  (entry.externalAttributes >> 16) & 0o170000 != 0o120000,
                  entry.uncompressedSize >= 0, entry.uncompressedSize <= 512 * 1024 * 1024 else {
                throw CodeFailure("This build contains an unsafe archive entry.")
            }
            total += entry.uncompressedSize
            guard total <= 4 * 1024 * 1024 * 1024 else { throw CodeFailure("This build is too large to cache on the phone.") }
            if parts.count >= 2, parts[0] == "Payload", parts[1].hasSuffix(".app") { apps.insert(String(parts[1])) }
        }
        guard apps.count == 1, let name = apps.first else { throw CodeFailure("Choose an IPA containing one iOS app.") }
        try archive.goToFirstFile()
        repeat {
            let entry = try archive.currentEntry()
            guard entry.filename.hasPrefix("Payload/" + name + "/") else { continue }
            let output = root.appendingPathComponent(entry.filename).standardizedFileURL
            guard output.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw CodeFailure("This archive path leaves the cache.") }
            if entry.isDirectory { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            else {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try archive.extractCurrentFile(to: output)
                try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: entry.posixPermissions)], ofItemAtPath: output.path)
            }
        } while archive.goToNextFile()
        return root.appendingPathComponent("Payload/" + name)
    }
}
