import Foundation
import CryptoKit
import Security

/// Distinct from the shared Orbit account identity. This key never syncs or
/// migrates to another phone. A host must bind its public key using an Apple
/// authenticated connection to the selected physical device, not a claimed UDID.
public final class CodeInstallEndpointIdentity: @unchecked Sendable {
    private let key: P256.Signing.PrivateKey
    public var publicKey: Data { key.publicKey.x963Representation }
    public init(service: String, accessGroup: String? = nil) throws {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "install-endpoint-v1",
            kSecAttrSynchronizable as String: false]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { key = try P256.Signing.PrivateKey(rawRepresentation: data) }
        else if status == errSecItemNotFound {
            let generated = P256.Signing.PrivateKey()
            query[kSecValueData as String] = generated.rawRepresentation
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            if added == errSecDuplicateItem {
                var existing: CFTypeRef?
                guard SecItemCopyMatching(lookup as CFDictionary, &existing) == errSecSuccess, let data = existing as? Data else { throw CodeFailure("Couldn’t load this phone’s installation key.") }
                key = try P256.Signing.PrivateKey(rawRepresentation: data)
            } else {
                guard added == errSecSuccess else { throw CodeFailure("Couldn’t save this phone’s installation key (\(added)).") }
                key = generated
            }
        } else { throw CodeOvernightSkip(stage: "credentials", message: "This phone’s installation key is unavailable until after its first unlock (\(status)).") }
    }
    public func sign(challenge: Data) throws -> Data {
        guard challenge.count >= 32, challenge.count <= 4096 else { throw CodeFailure("Invalid installation enrollment challenge.") }
        return try key.signature(for: Data("orbit-install-endpoint-v1\u{0}".utf8) + challenge).derRepresentation
    }
    public static func verify(signature: Data, challenge: Data, publicKey: Data) -> Bool {
        guard challenge.count >= 32, challenge.count <= 4096,
              let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(signature, for: Data("orbit-install-endpoint-v1\u{0}".utf8) + challenge)
    }
}
