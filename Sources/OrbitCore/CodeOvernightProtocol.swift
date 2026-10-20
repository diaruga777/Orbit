import Foundation

public enum CodeInstallProvider: String, Codable, CaseIterable, Sendable {
    case local, tailscale, syncthing, dumbpipe
    case native = "nativeAutomatic"
}
public struct CodeOvernightCapabilities: Codable, Equatable, Sendable {
    public var version = 1
    public var installOnly = true
    public var retainedArtifacts = true
    public var reconciliation = true
    public var providers: [CodeInstallProvider] = [.native]
    public var controlProviders: [CodeInstallProvider] = [.local, .tailscale, .syncthing, .dumbpipe]
    public var deviceFlowProxy = false
    public var datagrams = false
    public var selfUpdateThroughProxy = false
    public init() {}
}
public struct CodeOvernightPolicy: Codable, Equatable, Sendable {
    public var generation: String = UUID().uuidString
    public var cadenceDays = 1
    public var remoteProviders: [CodeInstallProvider] = []
    /// Explicit addresses only; public discovery and relay selection never run implicitly.
    public var tailscaleAddress: String?
    public var relayAddress: String?
    public init() {}
    public var providers: [CodeInstallProvider] { [.local] + remoteProviders.filter { $0 != .local } }
}
public struct CodeOvernightTarget: Codable, Equatable, Sendable {
    public var peerID: String
    public var deviceID: String
    public var project: CodeProject
    public var branch: String
    public var generation: String
    public init(peerID: String, deviceID: String, project: CodeProject, branch: String, generation: String) {
        self.peerID = peerID; self.deviceID = deviceID; self.project = project; self.branch = branch; self.generation = generation
    }
    public var key: String { [peerID, deviceID, project.path, project.scheme, generation].joined(separator: "\u{0}") }
}
public struct CodeOvernightError: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case transport, pairing, signing, locked, identity, cancelled, interrupted, integrity, unsupported, storage, build, unknown }
    public var kind: Kind
    public var stage: String
    public var domain: String
    public var code: Int
    public var recovery: String
    public init(_ kind: Kind, stage: String, recovery: String, domain: String = "Orbit", code: Int = 0) {
        self.kind = kind; self.stage = stage; self.recovery = recovery; self.domain = domain; self.code = code
    }
}
public struct CodeBuildArtifact: Codable, Equatable, Sendable {
    public var id: String
    public var jobID: String
    public var target: CodeOvernightTarget
    public var bundleID: String
    public var version: String
    public var build: String
    public var commit: String
    public var digest: String
    public var signingAuthority: String
    public var createdAt: Date
    public var byteCount: Int64
    public init(id: String, jobID: String, target: CodeOvernightTarget, bundleID: String, version: String,
                build: String, commit: String, digest: String, signingAuthority: String, byteCount: Int64, createdAt: Date = Date()) {
        self.id = id; self.jobID = jobID; self.target = target; self.bundleID = bundleID; self.version = version
        self.build = build; self.commit = commit; self.digest = digest; self.signingAuthority = signingAuthority
        self.byteCount = byteCount; self.createdAt = createdAt
    }
}
public struct CodeInstallAttempt: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case installing, succeeded, failed, waitingForPhone, cancelled, unknownCompletion }
    public var id = UUID().uuidString
    public var artifactID: String
    public var startedAt = Date()
    public var endedAt: Date?
    public var state: State = .installing
    public var provider: CodeInstallProvider
    public var sessionID: String?
    public var providerGeneration: String?
    public var connectionDescription: String?
    public var error: CodeOvernightError?
    public init(artifactID: String, provider: CodeInstallProvider) { self.artifactID = artifactID; self.provider = provider }
}
public struct CodeOvernightJob: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case accepted, building, waitingForPhone, installing, succeeded, failed, cancelled, unknownCompletion }
    public var id = UUID().uuidString
    public var requestID: String
    public var invocationID: String
    public var target: CodeOvernightTarget
    public var state: State = .accepted
    public var revision: UInt64 = 1
    public var acceptedAt = Date()
    public var builtAt: Date?
    public var installedAt: Date?
    public var synchronizedAt: Date?
    public var compilationJobID: String?
    public var artifact: CodeBuildArtifact?
    public var installs: [CodeInstallAttempt] = []
    public var error: CodeOvernightError?
    public init(requestID: String, invocationID: String, target: CodeOvernightTarget) {
        self.requestID = requestID; self.invocationID = invocationID; self.target = target
    }
    public var needsInstallReconciliation: Bool {
        artifact != nil && installedAt == nil && (state == .unknownCompletion || installs.contains(where: { $0.state == .unknownCompletion }))
    }
    public var hasActionableArtifact: Bool {
        artifact != nil && [.waitingForPhone, .installing, .unknownCompletion, .failed].contains(state)
    }
}
public struct CodeOvernightInvocation: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case started, skipped, accepted, succeeded, failed, expired, cancelled, unknownCompletion }
    public var id = UUID().uuidString
    public var startedAt = Date()
    public var endedAt: Date?
    public var scheduledFor: Date?
    public var nextRequestedAt: Date?
    public var reason: String
    public var timeZone = TimeZone.current.identifier
    public var localDay: String
    public var appVersion: String
    public var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    public var peerID: String?
    public var state: State = .started
    public var jobIDs: [String] = []
    public var controlProvider: CodeInstallProvider?
    public var error: CodeOvernightError?
    public init(reason: String, at date: Date = Date(), appVersion: String = "", calendar: Calendar = .current) {
        startedAt = date; self.reason = reason; self.appVersion = appVersion
        self.timeZone = calendar.timeZone.identifier
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        localDay = String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
    }
}
public struct CodeOvernightSubmission: Codable, Equatable, Sendable {
    public var invocationID: String
    public var target: CodeOvernightTarget
    public var localDay: String
    public init(invocationID: String, target: CodeOvernightTarget, localDay: String) {
        self.invocationID = invocationID; self.target = target; self.localDay = localDay
    }
}
public struct CodeOvernightDiagnosticEvent: Codable, Equatable, Sendable {
    public var date = Date()
    public var stage: String
    public var correlationID: String
    public var outcome: String
    public init(stage: String, correlationID: String, outcome: String) { self.stage = stage; self.correlationID = correlationID; self.outcome = outcome }
}

public struct CodeOvernightSkip: Error, LocalizedError, Sendable {
    public var stage: String
    public var message: String
    public init(stage: String, message: String) { self.stage = stage; self.message = message }
    public var errorDescription: String? { message }
}
