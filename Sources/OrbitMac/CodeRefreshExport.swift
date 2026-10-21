import Foundation
import CryptoKit
import OrbitCore

/// Export a retained, digest-verified build once; the phone then owns its refresh
/// source. This reads no account password, private signing key or pairing record.
actor CodeRefreshExport {
    private struct ArchiveInfo { var url: URL; var digest: String; var size: Int }
    private var preparing: [String: Task<ArchiveInfo, Error>] = [:]
    func chunk(artifact: CodeBuildArtifact, artifacts: URL, root: URL, offset: Int) async throws -> CodeRefreshArchiveChunk {
        guard offset >= 0 else { throw CodeFailure("Invalid build download offset.") }
        let id = artifact.id
        if preparing[id] == nil {
            preparing[id] = Task {
                let store = try CodeArtifactStore(root: artifacts)
                let app = try store.appURL(id)
                let (digest, size) = try CodeArtifactStore.digest(app)
                guard digest == artifact.digest, size == artifact.byteCount, size <= 2 * 1024 * 1024 * 1024 else { throw CodeFailure("This cached build changed or is too large. Build it again.") }
                let directory = root.appendingPathComponent(id)
                let payload = directory.appendingPathComponent("Payload")
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: app, to: payload.appendingPathComponent("App.app"))
                let ipa = directory.appendingPathComponent("Build.ipa")
                guard try await CodeProcess().run("/usr/bin/ditto", ["-c", "-k", "--keepParent", payload.path, ipa.path], directory: directory.path,
                    log: directory.appendingPathComponent("export.log"), timeout: 180) == 0 else { throw CodeFailure("Couldn’t prepare this build for the phone.") }
                try? FileManager.default.removeItem(at: payload)
                let handle = try FileHandle(forReadingFrom: ipa); defer { try? handle.close() }
                var hash = SHA256(), count = 0
                while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes); count += bytes.count }
                guard count > 0, count <= 2 * 1024 * 1024 * 1024 else { throw CodeFailure("The build archive is too large.") }
                return ArchiveInfo(url: ipa, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), size: count)
            }
        }
        let archive: ArchiveInfo
        do { archive = try await preparing[id]!.value } catch { preparing[id] = nil; throw error }
        guard offset <= archive.size else { throw CodeFailure("Invalid build download offset.") }
        let handle = try FileHandle(forReadingFrom: archive.url); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return CodeRefreshArchiveChunk(artifactID: id, digest: archive.digest, byteCount: archive.size, offset: offset,
            bytes: try handle.read(upToCount: 256 * 1024) ?? Data())
    }
}
