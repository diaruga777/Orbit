import Foundation
import CryptoKit
import OrbitCore

/// Signed products outlive detached checkouts and DerivedData. Default quota is
/// 8 GiB. Callers protect all ready, installing and uncertain artifact IDs.
public struct CodeArtifactStore: Sendable {
    public let root: URL
    public let quota: Int64
    public init(root: URL, quota: Int64 = 8 * 1024 * 1024 * 1024) throws {
        self.root = root; self.quota = quota
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func appURL(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CodeFailure("Invalid artifact identifier.") }
        return root.appendingPathComponent(id).appendingPathComponent("Product.app")
    }
    public func retain(app: URL, jobID: String, target: CodeOvernightTarget, commit: String, process: CodeProcess) async throws -> CodeBuildArtifact {
        let plist = try Self.info(app)
        guard let bundle = plist["CFBundleIdentifier"] as? String, !bundle.lowercased().contains("webdriveragent"),
              let version = plist["CFBundleShortVersionString"] as? String, let build = plist["CFBundleVersion"] as? String else {
            throw CodeFailure("The built app is missing its version or bundle identity.")
        }
        let id = UUID().uuidString
        let product = try appURL(id), directory = product.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.copyItem(at: app, to: product)
            let signing = try await validateSigning(product, deviceID: target.deviceID, process: process)
            let (digest, size) = try Self.digest(product)
            let used = try manifests().reduce(Int64(0)) { $0 + $1.byteCount }
            guard size <= quota, used <= quota - size else { throw CodeFailure("The retained build limit is full. Remove old builds on your Mac, then retry.") }
            let artifact = CodeBuildArtifact(id: id, jobID: jobID, target: target, bundleID: bundle, version: version,
                build: build, commit: commit, digest: digest, signingAuthority: signing, byteCount: size)
            let manifest = directory.appendingPathComponent("artifact.json")
            try JSONEncoder().encode(artifact).write(to: manifest, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            return artifact
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    public func validate(_ artifact: CodeBuildArtifact, process: CodeProcess) async throws -> URL {
        let app = try appURL(artifact.id)
        let manifest = try JSONDecoder().decode(CodeBuildArtifact.self, from: Data(contentsOf: app.deletingLastPathComponent().appendingPathComponent("artifact.json")))
        guard artifact == manifest else { throw CodeFailure("This build’s manifest changed. Build it again.") }
        let (digest, size) = try Self.digest(app)
        guard digest == artifact.digest, size == artifact.byteCount else { throw CodeFailure("This build changed after signing. Build it again.") }
        _ = try await validateSigning(app, deviceID: artifact.target.deviceID, process: process)
        return app
    }
    public func manifests() throws -> [CodeBuildArtifact] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap {
            try? JSONDecoder().decode(CodeBuildArtifact.self, from: Data(contentsOf: $0.appendingPathComponent("artifact.json")))
        }
    }
    public func prune(protecting ids: Set<String>) throws {
        let grouped = Dictionary(grouping: try manifests(), by: { [$0.target.peerID, $0.target.deviceID, $0.target.project.path, $0.target.project.scheme].joined(separator: "\u{0}") })
        for artifacts in grouped.values {
            for artifact in artifacts.sorted(by: { $0.createdAt > $1.createdAt }).dropFirst() where !ids.contains(artifact.id) {
                try FileManager.default.removeItem(at: try appURL(artifact.id).deletingLastPathComponent())
            }
        }
    }
    private func validateSigning(_ app: URL, deviceID: String, process: CodeProcess) async throws -> String {
        let log = root.appendingPathComponent("signing-" + UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: log) }
        guard try await process.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], directory: root.path, log: log, timeout: 30) == 0 else {
            throw CodeFailure("The retained app’s signature is invalid. Build it again.")
        }
        let apps = [app] + ((try? FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "appex" }
        for product in apps {
            let decoded = root.appendingPathComponent(UUID().uuidString + ".plist")
            defer { try? FileManager.default.removeItem(at: decoded) }
            guard try await process.run("/usr/bin/security", ["cms", "-D", "-i", product.appendingPathComponent("embedded.mobileprovision").path, "-o", decoded.path], directory: root.path, log: log, timeout: 20) == 0,
                  let profile = try PropertyListSerialization.propertyList(from: Data(contentsOf: decoded), format: nil) as? [String: Any],
                  let expires = profile["ExpirationDate"] as? Date, expires > Date(),
                  (profile["ProvisionedDevices"] as? [String])?.contains(deviceID) == true,
                  (profile["Entitlements"] as? [String: Any])?["get-task-allow"] as? Bool == true else {
                throw CodeFailure("This phone is not eligible for the app’s development provisioning profile. Check signing on your Mac.")
            }
        }
        guard try await process.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path], directory: root.path, log: log, timeout: 20) == 0 else { throw CodeFailure("Couldn’t inspect the app’s signing identity.") }
        return String(decoding: try Data(contentsOf: log), as: UTF8.self).components(separatedBy: .newlines).first { $0.hasPrefix("TeamIdentifier=") } ?? "development"
    }
    static func info(_ app: URL) throws -> [String: Any] {
        guard let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] else { throw CodeFailure("Couldn’t read the built app.") }
        return result
    }
    static func digest(_ app: URL) throws -> (String, Int64) {
        let base = app.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { throw CodeFailure("Couldn’t inspect the retained build.") }
        var hash = SHA256(), size: Int64 = 0
        for file in enumerator.compactMap({ $0 as? URL }).sorted(by: { $0.path < $1.path }) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let relative = String(file.path.dropFirst(app.path.count + 1))
            hash.update(data: Data(relative.utf8)); hash.update(data: Data([0]))
            if values.isSymbolicLink == true {
                guard file.resolvingSymlinksInPath().path.hasPrefix(base) else { throw CodeFailure("The retained build contains a link outside its bundle.") }
                hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8))
            } else if values.isRegularFile == true {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                    hash.update(data: bytes); size += Int64(bytes.count)
                }
            }
            hash.update(data: Data([0]))
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}
