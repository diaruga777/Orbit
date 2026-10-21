import Foundation
import Security
import OrbitCore

/// Separate from Luna's synchronized connection identity. Signing credentials
/// and host pairing secrets stay on this phone and never go through Mac RPCs.
struct CodeRefreshSecrets {
    var service: String { (Bundle.main.bundleIdentifier ?? "Orbit") + ".local-refresh" }
    func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CodeFailure("Unlock this phone to use refresh credentials.") }
        return result as? Data
    }
    func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, rhs in rhs } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw CodeFailure("Couldn’t save refresh credentials on this phone.") }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CodeFailure("Unlock this phone to remove refresh credentials.") }
    }
    func clear() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CodeFailure("Unlock this phone to remove refresh credentials.") }
    }
}
