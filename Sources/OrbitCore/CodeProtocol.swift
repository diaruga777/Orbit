import Foundation

public enum CodeWire {
    public static let namespace = "orbit-v1"
    public static let maxFileBytes = 2 * 1024 * 1024
    public static let maxPayloadBytes = 12 * 1024 * 1024
}
public struct CodeFailure: Error, LocalizedError, Codable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct CodeDocument: Codable, Equatable, Sendable {
    public var path: String
    public var text: String
    public var version: String
    public var encoding: String
    public init(path: String, text: String, version: String, encoding: String = "utf8") {
        self.path = path; self.text = text; self.version = version; self.encoding = encoding
    }
}
public struct CodeProject: Codable, Equatable, Sendable {
    public var path: String
    public var scheme: String
    public var appID: String
    public var developmentTeam: String?
    public var minimumProfileHours: Int?
    public var groupID: String
    public init(path: String, scheme: String = "", appID: String = "", groupID: String = "") {
        self.path = path; self.scheme = scheme; self.appID = appID; self.groupID = groupID
    }
    public var root: String { URL(fileURLWithPath: path).deletingLastPathComponent().path }
    public var xcodeArguments: [String] { [path.hasSuffix(".xcworkspace") ? "-workspace" : "-project", path, "-scheme", scheme] + (developmentTeam.map { ["DEVELOPMENT_TEAM=" + $0] } ?? []) }
}
public struct CodePosition: Codable, Equatable, Sendable {
    public var line: Int
    public var character: Int
    public init(line: Int, character: Int) { self.line = line; self.character = character }
    public static func at(utf16Offset: Int, in text: String) -> Self {
        let ns = text as NSString
        let prefix = ns.substring(to: max(0, min(utf16Offset, ns.length)))
        let lines = prefix.components(separatedBy: "\n")
        return Self(line: lines.count - 1, character: (lines.last! as NSString).length)
    }
    public func offset(in text: String) -> Int? {
        let lines = text.components(separatedBy: "\n")
        guard line >= 0, line < lines.count, character >= 0, character <= (lines[line] as NSString).length else { return nil }
        return lines.prefix(line).reduce(0) { $0 + ($1 as NSString).length + 1 } + character
    }
}
public struct CodeDiagnostic: Codable, Equatable, Sendable {
    public var line: Int
    public var character: Int
    public var message: String
    public var severity: Int
    public init(line: Int, character: Int, message: String, severity: Int = 1) {
        self.line = line; self.character = character; self.message = message; self.severity = severity
    }
}
public struct CodeCompletion: Codable, Equatable, Sendable {
    public var label: String
    public var detail: String
    public var text: String
    public var start: CodePosition?
    public var end: CodePosition?
    public init(label: String, detail: String = "", text: String, start: CodePosition? = nil, end: CodePosition? = nil) {
        self.label = label; self.detail = detail; self.text = text; self.start = start; self.end = end
    }
}
public struct CodeJob: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, succeeded, failed, cancelled }
    public var id: String
    public var title: String
    public var state: State
    public var log: String
    public var failureMessage: String?
    public var startedAt: Date
    public var progress: CodeJobProgress?
    public var installHandoff: CodeInstallHandoff?
    public var projectKey: String?
    public var requestID: String?
    public var requestFingerprint: String?
    public var builtAt: Date?
    public var commitHash: String?
    public var artifact: CodeBuildArtifact?
    public init(id: String, title: String, state: State = .running, log: String = "") {
        self.id = id; self.title = title; self.state = state; self.log = log; startedAt = Date()
    }
}
public struct CodeRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case open, save, schemes, apps, devices, branches, runOnDevice, analyze, complete, prepare, build, deploy, job, cancel, acknowledgeInstall, overnightCapabilities, overnightSubmit, overnightStatus, overnightInstall, overnightCancel, overnightDiagnostics, endpointBegin, endpointFinish, endpointStatus, endpointRevoke, endpointReadyBegin, endpointReadyFinish, endpointPoll, endpointStop }
    public var id: String = UUID().uuidString
    public var operation: Operation
    public var path: String = ""
    public var text: String = ""
    public var version: String = ""
    public var project: CodeProject?
    public var deviceBuild: CodeDeviceBuild?
    public var reverse: CodeReverseControl?
    public var endpoint: CodeEndpointEnrollmentRequest?
    public var overnight: CodeOvernightSubmission?
    public var position: CodePosition?
    public var jobID: String = ""
    public var handoffToken: String?
    public var bufferVersion: Int = 0
    public init(_ operation: Operation, path: String = "") { self.operation = operation; self.path = path }
}
public struct CodeResponse: Codable, Sendable {
    public var reverseChallenge: Data?
    public var reverseReadiness: CodeReverseReadiness?
    public var reverseFlows: [CodeReverseFlowDemand]?
    public var endpointChallenge: CodeEndpointChallengeReceipt?
    public var endpointBindings: [CodeEndpointBinding]?
    public var supportsOvernightBuilds: Bool?
    public var overnightCapabilities: CodeOvernightCapabilities?
    public var overnightJobs: [CodeOvernightJob]?
    public var overnightDiagnostics: [String: Data]?
    public var apps: [CodeBuildApp]?
    public var devices: [CodeDevice]?
    public var branches: [String]?
    public var document: CodeDocument?
    public var conflict: Bool = false
    public var schemes: [String] = []
    public var diagnostics: [CodeDiagnostic] = []
    public var completions: [CodeCompletion] = []
    public var job: CodeJob?
    public var error: String?
    public init() {}
}
/// The host injects the existing Orbit authenticated transport.
public struct CodeClient: Sendable {
    public var exchange: @Sendable (Data) async throws -> Data
    public init(exchange: @escaping @Sendable (Data) async throws -> Data) { self.exchange = exchange }
    public func call(_ request: CodeRequest) async throws -> CodeResponse {
        let data = try JSONEncoder().encode(request)
        guard data.count <= CodeWire.maxPayloadBytes else { throw CodeFailure("This request is too large.") }
        let reply = try await exchange(data)
        guard reply.count <= CodeWire.maxPayloadBytes else { throw CodeFailure("The Mac returned too much data.") }
        let response = try JSONDecoder().decode(CodeResponse.self, from: reply)
        if let error = response.error { throw CodeFailure(error) }
        return response
    }
}
