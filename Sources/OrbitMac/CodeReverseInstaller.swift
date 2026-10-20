import Foundation
import OrbitCore

public struct CodeReverseInstallerConfiguration: Sendable {
    public var hub: CodeReverseFlowHub
    public var helper: URL
    public var diagnostics: URL?
    public var forwarderBundleID: String
    public init(hub: CodeReverseFlowHub, helper: URL, forwarderBundleID: String, diagnostics: URL? = nil) { self.hub = hub; self.helper = helper; self.forwarderBundleID = forwarderBundleID; self.diagnostics = diagnostics }
    public var available: Bool { FileManager.default.isExecutableFile(atPath: helper.path) && !forwarderBundleID.isEmpty }
}
public struct CodeInstallRoute: Sendable {
    public var provider: CodeInstallProvider
    public var sessionID: String
    public var generation: String
    public var description: String
}
public struct CodeReverseInstaller: CodeArtifactInstalling {
    private let configuration: CodeReverseInstallerConfiguration
    public init(configuration: CodeReverseInstallerConfiguration) { self.configuration = configuration }
    public func install(_ artifact: CodeBuildArtifact, app: URL, process: CodeProcess) async -> CodeArtifactInstallResult {
        await install(artifact, app: app, process: process, recordRoute: { _ in })
    }
    private struct Artifact: Encodable { var deviceID: String; var bundleID: String; var version: String; var build: String; var package: String; var forwarderBundleID: String }
    private struct Request: Encodable { var artifact: Artifact; var broker: String; var token: String }
    struct Reply: Decodable { var confirmed: Bool; var handedOff: Bool; var definitiveFailure: Bool; var stage: String; var kind: String?; var error: String? }
    public func install(_ artifact: CodeBuildArtifact, app: URL, process: CodeProcess,
                        recordRoute: @escaping @Sendable (CodeInstallRoute) async throws -> Void) async -> CodeArtifactInstallResult {
        let lock = CodeDeviceInstallLock.shared
        let token: UUID
        do { token = try await lock.acquire(artifact.target.deviceID) } catch { return CodeArtifactInstallResult(state: .cancelled) }
        defer { Task { await lock.release(artifact.target.deviceID, token: token) } }
        let readiness: CodeReverseReadiness
        do { readiness = try await configuration.hub.readiness(deviceID: artifact.target.deviceID) }
        catch { return CodeArtifactInstallResult(state: .waitingForPhone, error: CodeOvernightError(.transport, stage: "proxy.readiness", recovery: "The build is ready. This phone needs an active authorized connection to install it.")) }
        guard artifact.bundleID != configuration.forwarderBundleID else {
            return CodeArtifactInstallResult(state: .failed, error: CodeOvernightError(.unsupported, stage: "proxy.selfUpdate", recovery: "Orbit needs an independent Apple device connection to update itself."))
        }
        var started = false
        do {
            guard configuration.available else { throw CodeFailure("The Mac installation helper is unavailable.") }
            let broker = try CodeUnixAppleBroker(hub: configuration.hub, readiness: readiness)
            defer { broker.close() }
            let root = broker.directory, log = root.appendingPathComponent("helper.log")
            let output = root.appendingPathComponent("result.jsonl")
            defer { retainDiagnostics(output) }
            // This helper is nested code in the staged signed application.
            guard try await process.run("/usr/bin/codesign", ["--verify", "--strict", configuration.helper.path], directory: root.path, log: log, timeout: 10) == 0 else { throw CodeFailure("The Mac installation helper’s signature is invalid.") }
            let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard capacity > artifact.byteCount * 2 + 100_000_000 else { throw CodeFailure("The Mac needs more free space to prepare this installation.") }
            let payload = root.appendingPathComponent("Payload", isDirectory: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard try await process.run("/usr/bin/ditto", [app.path, payload.appendingPathComponent("Product.app").path], directory: root.path, log: log, timeout: 120) == 0 else { throw CodeFailure("The Mac couldn’t copy the retained app.") }
            let package = root.appendingPathComponent("Product.ipa")
            guard try await process.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", payload.path, package.path], directory: root.path, log: log, timeout: 120) == 0 else { throw CodeFailure("The Mac couldn’t package the retained app.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: package.path)
            let request = Request(artifact: Artifact(deviceID: artifact.target.deviceID, bundleID: artifact.bundleID, version: artifact.version, build: artifact.build,
                package: package.path, forwarderBundleID: configuration.forwarderBundleID), broker: broker.path, token: broker.token)
            let manifest = root.appendingPathComponent("request.json")
            try JSONEncoder().encode(request).write(to: manifest, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            let description = "App-hosted authenticated Apple stream; configured " + readiness.provider.rawValue + "; underlay unverified"
            // Persist the actual route/session before the helper can send Install.
            try await recordRoute(CodeInstallRoute(provider: readiness.provider, sessionID: readiness.id, generation: readiness.generation, description: description))
            try Task.checkCancellation(); started = true
            _ = try await process.run(configuration.helper.path, [manifest.path], directory: root.path, log: output, timeout: 500)
            let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 128_000, let line = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").last else { throw CodeFailure("The Mac installer returned no bounded result.") }
            let reply = try JSONDecoder().decode(Reply.self, from: Data(line.utf8))
            return Self.result(reply, description: description)
        } catch is CancellationError {
            return CodeArtifactInstallResult(state: started ? .unknownCompletion : .cancelled,
                error: CodeOvernightError(.cancelled, stage: "proxy.install", recovery: started ? "Installation was interrupted. Reconnect to confirm its result." : "Installation cancelled."))
        } catch {
            return CodeArtifactInstallResult(state: started ? .unknownCompletion : .failed,
                error: CodeOvernightError(started ? .unknown : .storage, stage: "proxy.install", recovery: started ? "The installer’s result couldn’t be confirmed. Reconnect before retrying." : error.localizedDescription))
        }
    }
    private func retainDiagnostics(_ output: URL) {
        guard let logs = configuration.diagnostics,
              let handle = try? FileHandle(forReadingFrom: output) else { return }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 128_000) else { return }
        let destination = logs.appendingPathComponent(UUID().uuidString + ".proxy.log")
        try? bytes.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let files = ((try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { UUID(uuidString: String($0.lastPathComponent.prefix(36))) != nil && ["log", "json"].contains($0.pathExtension) }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var total = 0
        for file in files {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if total > 18_000_000 { try? FileManager.default.removeItem(at: file) }
        }
    }
    static func result(_ reply: Reply, description: String) -> CodeArtifactInstallResult {
        if reply.confirmed { return CodeArtifactInstallResult(state: .succeeded, connectionDescription: description) }
        let kind = CodeOvernightError.Kind(rawValue: reply.kind ?? "unknown") ?? .unknown
        let state: CodeInstallAttempt.State = reply.handedOff && !reply.definitiveFailure ? .unknownCompletion : (kind == .transport ? .waitingForPhone : .failed)
        let recovery: String
        switch kind {
        case .pairing: recovery = "Check this phone’s Apple pairing and Developer Mode on your Mac."
        case .identity: recovery = "The Apple device identity changed. Authorize this phone again on your Mac."
        case .locked: recovery = "Unlock this phone, then retry installation."
        case .signing: recovery = "Check the app’s development signing and provisioning on your Mac."
        case .transport: recovery = "The build is ready. Reconnect this phone to retry or confirm installation."
        default: recovery = "Installation couldn’t be confirmed. Check Mac diagnostics before retrying."
        }
        return CodeArtifactInstallResult(state: state, error: CodeOvernightError(kind, stage: "proxy." + reply.stage, recovery: recovery), connectionDescription: description)
    }
}
public struct CodeFallbackInstaller: CodeArtifactInstalling {
    public var native: any CodeArtifactInstalling
    public var remote: any CodeArtifactInstalling
    public init(native: any CodeArtifactInstalling, remote: any CodeArtifactInstalling) { self.native = native; self.remote = remote }
    public func install(_ artifact: CodeBuildArtifact, app: URL, process: CodeProcess) async -> CodeArtifactInstallResult {
        await install(artifact, app: app, process: process, recordRoute: { _ in })
    }
    public func install(_ artifact: CodeBuildArtifact, app: URL, process: CodeProcess, recordRoute: @escaping @Sendable (CodeInstallRoute) async throws -> Void) async -> CodeArtifactInstallResult {
        let first = await native.install(artifact, app: app, process: process, recordRoute: recordRoute)
        guard first.state == .waitingForPhone, first.error?.kind == .transport, !Task.isCancelled else { return first }
        return await remote.install(artifact, app: app, process: process, recordRoute: recordRoute)
    }
}
