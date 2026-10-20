import Foundation

public enum CodeAppleStreamService: String, Codable, Sendable {
    case lockdown, afc
    case installation = "installation-proxy"
    public func permits(port: UInt16) -> Bool {
        port > 0 && (self == .lockdown ? port == 62078 : port != 62078)
    }
}
public struct CodeReverseControl: Codable, Sendable {
    public var sessionID = ""
    public var bindingID = ""
    public var generation = ""
    public var token = ""
    public var signature = Data()
    public var sequence: UInt64 = 0
    public var provider: CodeInstallProvider = .local
    public init() {}
}
public struct CodeReverseReadiness: Codable, Equatable, Sendable {
    public var id: String
    public var token: String
    public var bindingID: String
    public var deviceID: String
    public var generation: String
    public var provider: CodeInstallProvider
    public init(id: String, token: String, bindingID: String, deviceID: String, generation: String, provider: CodeInstallProvider) {
        self.id = id; self.token = token; self.bindingID = bindingID; self.deviceID = deviceID; self.generation = generation; self.provider = provider
    }
}
public struct CodeReverseFlowDemand: Codable, Equatable, Sendable {
    public var id: String
    public var sessionID: String
    public var bindingID: String
    public var deviceID: String
    public var generation: String
    public var service: CodeAppleStreamService
    public var port: UInt16
    public var challenge: Data
    public init(id: String, readiness: CodeReverseReadiness, service: CodeAppleStreamService, port: UInt16, challenge: Data) {
        self.id = id; sessionID = readiness.id; bindingID = readiness.bindingID; deviceID = readiness.deviceID
        generation = readiness.generation; self.service = service; self.port = port; self.challenge = challenge
    }
}
public struct CodeReverseStreamProof: Codable, Sendable {
    public var flowID: String
    public var sessionID: String
    public var signature: Data
    public init(flowID: String, sessionID: String, signature: Data) { self.flowID = flowID; self.sessionID = sessionID; self.signature = signature }
}
public struct CodeReverseChallenge: Codable, Sendable {
    public var version = 1
    public var purpose: String
    public var id: String
    public var accountPeerID: String
    public var bindingID: String
    public var deviceID: String
    public var generation: String
    public var nonce = UUID().uuidString + UUID().uuidString
    public var service: CodeAppleStreamService?
    public var port: UInt16?
    public init(purpose: String, id: String, accountPeerID: String, bindingID: String, deviceID: String, generation: String,
                service: CodeAppleStreamService? = nil, port: UInt16? = nil) {
        self.purpose = purpose; self.id = id; self.accountPeerID = accountPeerID; self.bindingID = bindingID
        self.deviceID = deviceID; self.generation = generation; self.service = service; self.port = port
    }
}
public struct CodeReverseRenewal: Codable, Sendable {
    public var sequence: UInt64
    public init(sequence: UInt64) { self.sequence = sequence }
}
