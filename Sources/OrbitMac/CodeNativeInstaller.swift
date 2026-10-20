import Foundation
import OrbitCore

public struct CodeArtifactInstallResult: Sendable {
    public var state: CodeInstallAttempt.State
    public var error: CodeOvernightError?
    public var connectionDescription: String?
    public init(state: CodeInstallAttempt.State, error: CodeOvernightError? = nil, connectionDescription: String? = nil) {
        self.state = state; self.error = error; self.connectionDescription = connectionDescription
    }
}
public protocol CodeArtifactInstalling: Sendable {
    func install(_ artifact: CodeBuildArtifact, app: URL, process: CodeProcess) async -> CodeArtifactInstallResult
    func install(_ artifact: CodeBuildArtifact, app: URL, process: CodeProcess, recordRoute: @escaping @Sendable (CodeInstallRoute) async throws -> Void) async -> CodeArtifactInstallResult
}
public extension CodeArtifactInstalling {
    func install(_ artifact: CodeBuildArtifact, app: URL, process: CodeProcess, recordRoute: @escaping @Sendable (CodeInstallRoute) async throws -> Void) async -> CodeArtifactInstallResult {
        await install(artifact, app: app, process: process)
    }
}
/// CoreDevice chooses the native route. Report that fact; localNetwork does not
/// prove a LAN underlay rather than a separately configured Tailscale bridge.
public struct CodeNativeInstaller: CodeArtifactInstalling {
    public let logs: URL
    private let record: @Sendable (CodeOvernightDiagnosticEvent) -> Void
    public init(logs: URL, record: @escaping @Sendable (CodeOvernightDiagnosticEvent) -> Void = { _ in }) { self.logs = logs; self.record = record }
    public func install(_ artifact: CodeBuildArtifact, app: URL, process: CodeProcess) async -> CodeArtifactInstallResult {
        let installLock = CodeDeviceInstallLock.shared
        let token: UUID
        do { token = try await installLock.acquire(artifact.target.deviceID) }
        catch { return CodeArtifactInstallResult(state: .cancelled) }
        defer { Task { await installLock.release(artifact.target.deviceID, token: token) } }
        let prefix = logs.appendingPathComponent(UUID().uuidString)
        defer { pruneDiagnostics(protecting: prefix.lastPathComponent) }
        var handedOff = false
        do {
            let details = try await query(["device", "info", "details", "--device", artifact.target.deviceID], prefix: prefix, stage: "identity", process: process)
            let result = details["result"] as? [String: Any] ?? [:]
            let properties = result["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any] ?? result["hardwareProperties"] as? [String: Any] ?? [:]
            guard hardware["udid"] as? String == artifact.target.deviceID,
                  hardware["reality"] as? String == "physical" else {
                return CodeArtifactInstallResult(state: .failed, error: CodeOvernightError(.identity, stage: "identity", recovery: "The connected phone doesn’t match the selected device."))
            }
            let connection = properties["connection"] as? [String: Any] ?? result["connectionProperties"] as? [String: Any] ?? [:]
            let route = "CoreDevice automatic; " + (connection["transportType"] as? String ?? "unknown") + "; " + (connection["tunnelTransportProtocol"] as? String ?? "unknown")
            // Readback reconciles a lost install reply or interrupted self-update.
            if let before = try? await installed(artifact, prefix: prefix, stage: "before", process: process), before {
                return CodeArtifactInstallResult(state: .succeeded, connectionDescription: route)
            }
            handedOff = true
            _ = try await query(["device", "install", "app", "--device", artifact.target.deviceID, app.path], prefix: prefix, stage: "install", process: process, timeout: 120)
            if try await installed(artifact, prefix: prefix, stage: "readback", process: process) {
                return CodeArtifactInstallResult(state: .succeeded, connectionDescription: route)
            }
            return CodeArtifactInstallResult(state: .unknownCompletion,
                error: CodeOvernightError(.unknown, stage: "readback", recovery: "The installer finished, but this revision couldn’t be confirmed. Refresh when your phone reconnects."), connectionDescription: route)
        } catch is CancellationError {
            return CodeArtifactInstallResult(state: handedOff ? .unknownCompletion : .cancelled,
                error: CodeOvernightError(.cancelled, stage: handedOff ? "install" : "connection", recovery: handedOff ? "Installation was interrupted. Refresh its status before retrying." : "Installation cancelled."))
        } catch let error as NativeCommandError {
            let kind = Self.classify(error.document)
            return CodeArtifactInstallResult(state: handedOff && kind == .transport ? .unknownCompletion : (kind == .transport ? .waitingForPhone : .failed),
                error: CodeOvernightError(kind, stage: handedOff ? "install" : "connection", recovery: Self.recovery(kind), domain: error.domain, code: error.code))
        } catch {
            return CodeArtifactInstallResult(state: handedOff ? .unknownCompletion : .waitingForPhone,
                error: CodeOvernightError(.unknown, stage: handedOff ? "readback" : "connection", recovery: "Couldn’t confirm the phone’s status. Check its connection and refresh."))
        }
    }
    private func installed(_ artifact: CodeBuildArtifact, prefix: URL, stage: String, process: CodeProcess) async throws -> Bool {
        let document = try await query(["device", "info", "apps", "--device", artifact.target.deviceID, "--bundle-id", artifact.bundleID], prefix: prefix, stage: stage, process: process)
        return Self.matchesReadback(document, artifact: artifact)
    }
    static func matchesReadback(_ document: [String: Any], artifact: CodeBuildArtifact) -> Bool {
        guard let apps = (document["result"] as? [String: Any])?["apps"] as? [[String: Any]] else { return false }
        return apps.contains { app in
            // Do not substitute the bundle identifier for a revision check.
            app["bundleIdentifier"] as? String == artifact.bundleID &&
                app["version"] as? String == artifact.version &&
                (app["bundleVersion"] as? String ?? app["buildVersion"] as? String) == artifact.build
        }
    }
    private func query(_ arguments: [String], prefix: URL, stage: String, process: CodeProcess, timeout: Int = 30) async throws -> [String: Any] {
        let json = prefix.appendingPathExtension(stage + ".json")
        let log = prefix.appendingPathExtension(stage + ".log")
        record(CodeOvernightDiagnosticEvent(stage: "installer." + stage, correlationID: prefix.lastPathComponent, outcome: "started"))
        let exit = try await process.run("/usr/bin/xcrun", ["devicectl"] + arguments + ["--timeout", String(timeout), "--json-output", json.path], directory: logs.path, log: log, timeout: TimeInterval(timeout + 10))
        // Bound retained diagnostics. No credentials or pairing data are queried.
        for file in [json, log] {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 128_000,
               let handle = try? FileHandle(forUpdating: file) { try? handle.truncate(atOffset: 128_000); try? handle.close() }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        record(CodeOvernightDiagnosticEvent(stage: "installer." + stage, correlationID: prefix.lastPathComponent, outcome: "exit-" + String(exit)))
        let document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: json))) as? [String: Any] ?? [:]
        guard exit == 0, (document["info"] as? [String: Any])?["outcome"] as? String == "success" else {
            let error = document["error"] as? [String: Any] ?? [:]
            throw NativeCommandError(document: document, domain: error["domain"] as? String ?? "CoreDevice", code: error["code"] as? Int ?? Int(exit))
        }
        return document
    }
    private func pruneDiagnostics(protecting prefix: String) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { UUID(uuidString: String($0.lastPathComponent.prefix(36))) != nil && ["log", "json"].contains($0.pathExtension) }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var total = 0
        for file in files {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if total > 18_000_000 && !file.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
        }
    }
    static func classify(_ document: [String: Any]) -> CodeOvernightError.Kind {
        // Classification controls fallback, so unknown errors fail closed.
        let error = document["error"] ?? [:]
        let text = String(describing: error).lowercased()
        if text.contains("locked") || text.contains("passcode") { return .locked }
        if text.contains("provision") || text.contains("signature") || text.contains("signing") { return .signing }
        if text.contains("pair") || text.contains("trust") || text.contains("authentication") { return .pairing }
        if text.contains("not connected") || text.contains("unreachable") || text.contains("timed out") || text.contains("connection lost") || text.contains("device was not found") { return .transport }
        return .unknown
    }
    private static func recovery(_ kind: CodeOvernightError.Kind) -> String {
        switch kind {
        case .locked: return "Unlock your phone, then retry installation."
        case .signing: return "Check the app’s development signing and provisioning on your Mac."
        case .pairing: return "Check device trust and Developer Mode in Xcode on your Mac."
        case .transport: return "The build is ready. Installation will retry when your phone reconnects."
        default: return "Installation couldn’t be confirmed. Check the Mac diagnostics before retrying."
        }
    }
}
private struct NativeCommandError: Error {
    var document: [String: Any]
    var domain: String
    var code: Int
}
