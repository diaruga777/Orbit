import Foundation
import CryptoKit

public struct CodeEndpointEnrollmentRequest: Codable, Sendable {
    public var id: String
    public var deviceID: String
    public var publicKey: Data
    public init(id: String = UUID().uuidString, deviceID: String = "", publicKey: Data = Data()) {
        self.id = id; self.deviceID = deviceID; self.publicKey = publicKey
    }
}
public struct CodeEndpointChallengeReceipt: Codable, Sendable {
    public var id: String
    public var deviceID: String
    public init(id: String, deviceID: String) { self.id = id; self.deviceID = deviceID }
}
public struct CodeEndpointBinding: Codable, Equatable, Sendable {
    public var id: String
    public var accountPeerID: String
    public var deviceID: String
    public var publicKey: Data
    public var enrolledAt: Date
    public init(id: String, accountPeerID: String, deviceID: String, publicKey: Data, enrolledAt: Date = Date()) {
        self.id = id; self.accountPeerID = accountPeerID; self.deviceID = deviceID; self.publicKey = publicKey; self.enrolledAt = enrolledAt
    }
}
public struct CodeEndpointChallenge: Codable, Sendable {
    public var version: Int = 1
    public var id: String
    public var accountPeerID: String
    public var deviceID: String
    public var publicKey: Data
    public var nonce: Data
    public init(id: String, accountPeerID: String, deviceID: String, publicKey: Data, nonce: Data) {
        self.id = id; self.accountPeerID = accountPeerID; self.deviceID = deviceID; self.publicKey = publicKey; self.nonce = nonce
    }
}
public struct CodeEndpointProof: Codable, Sendable {
    public var challenge: Data
    public var signature: Data
    public init(challenge: Data, signature: Data) { self.challenge = challenge; self.signature = signature }
}

/// Fixed app-private paths only. Neither side accepts a caller-selected container
/// or path. Challenge bytes arrive through Apple's authenticated device channel;
/// a Orbit RPC carries only the receipt, never the proof used by the Mac.
public enum CodeEndpointEnrollment {
    public static let directory = "Library/Application Support/OrbitInstall"
    public static func path(id: String, proof: Bool) throws -> String {
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id else { throw CodeFailure("Invalid phone authorization ID.") }
        return directory + "/" + id + (proof ? "/proof.json" : "/challenge.json")
    }
    public static func writeProof(receipt: CodeEndpointChallengeReceipt, container: URL,
                                  publicKey: Data, sign: (Data) throws -> Data) throws {
        let challengeFile = container.appendingPathComponent(try path(id: receipt.id, proof: false))
        guard FileManager.default.fileExists(atPath: challengeFile.path),
              challengeFile.resolvingSymlinksInPath().path.hasPrefix(container.resolvingSymlinksInPath().path + "/") else {
            throw CodeFailure("The authorization didn’t reach this phone. Select this phone on your Mac and try again.")
        }
        let values = try challengeFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4096 else { throw CodeFailure("Invalid phone authorization file.") }
        let data = try Data(contentsOf: challengeFile)
        let challenge = try JSONDecoder().decode(CodeEndpointChallenge.self, from: data)
        guard challenge.version == 1, challenge.id == receipt.id, challenge.deviceID == receipt.deviceID,
              challenge.publicKey == publicKey, challenge.nonce.count == 32, !challenge.accountPeerID.isEmpty else {
            throw CodeFailure("The authorization belongs to a different phone. Try again with this phone selected.")
        }
        let proof = CodeEndpointProof(challenge: data, signature: try sign(data))
        let destination = container.appendingPathComponent(try path(id: receipt.id, proof: true))
        try JSONEncoder().encode(proof).write(to: destination, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        #else
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        #endif
    }
    public static func clean(container: URL, id: String) {
        guard let path = try? path(id: id, proof: false) else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent(path).deletingLastPathComponent())
    }
}
