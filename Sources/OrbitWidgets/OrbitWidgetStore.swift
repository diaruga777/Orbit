import Foundation
import Security

/// Shared keychain storage also works without a paid App Group capability.
/// The app and extension explicitly share the containing app's keychain group.
/// Scripts and their K-V state never synchronize through iCloud Keychain.
public final class OrbitWidgetStore: @unchecked Sendable {
    private let directory: URL?
    private let group: String?
    private let lock = NSRecursiveLock()
    public init(directory: URL? = nil, accessGroup: String? = nil) {
        self.directory = directory
        group = accessGroup ?? Bundle.main.object(forInfoDictionaryKey: "OrbitWidgetKeychainGroup") as? String
    }
    private func read(_ key: String) throws -> Data? {
        if let directory { return try? Data(contentsOf: directory.appendingPathComponent(key)) }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Orbit.Widgets.v1",
            kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if let group { query[kSecAttrAccessGroup as String] = group }
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess else { throw OrbitWidgetError("Unlock your phone to load widgets.") }
        return result as? Data
    }
    private func write(_ data: Data?, key: String) throws {
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(key)
            if let data { try data.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }; return
        }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Orbit.Widgets.v1",
            kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
        if let group { query[kSecAttrAccessGroup as String] = group }
        guard let data else { let result = SecItemDelete(query as CFDictionary); guard result == errSecSuccess || result == errSecItemNotFound else { throw OrbitWidgetError("Couldn’t remove this widget.") }; return }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var code = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound { code = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard code == errSecSuccess else { throw OrbitWidgetError("Couldn’t save this widget on your phone.") }
    }
    private func identifiers() throws -> [String] { try read("index").map { try JSONDecoder().decode([String].self, from: $0) } ?? [] }
    public func scripts() throws -> [OrbitWidgetScript] {
        lock.lock(); defer { lock.unlock() }
        return try identifiers().compactMap { try script($0) }.sorted { $0.definition.name.localizedStandardCompare($1.definition.name) == .orderedAscending }
    }
    public func script(_ id: String) throws -> OrbitWidgetScript? {
        guard Self.validID(id) else { throw OrbitWidgetError("Invalid widget identifier.") }
        return try read("script-" + id).map { try JSONDecoder().decode(OrbitWidgetScript.self, from: $0) }
    }
    public func install(_ source: String) throws {
        lock.lock(); defer { lock.unlock() }
        let script = try OrbitWidgetScript(source: source)
        var ids = try identifiers()
        guard ids.contains(script.id) || ids.count < 24 else { throw OrbitWidgetError("Remove a widget before adding another.") }
        // Every update is reviewed by the caller, including changes in domains.
        try write(JSONEncoder().encode(script), key: "script-" + script.id)
        for family in Self.families { try write(nil, key: "output-" + script.id + "-" + family) }
        if !ids.contains(script.id) { ids.append(script.id) }
        try write(JSONEncoder().encode(ids), key: "index")
    }
    public func remove(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.validID(id) else { throw OrbitWidgetError("Invalid widget identifier.") }
        try write(JSONEncoder().encode(identifiers().filter { $0 != id }), key: "index")
        try write(nil, key: "script-" + id)
        for family in Self.families { try write(nil, key: "output-" + id + "-" + family) }
        try write(nil, key: "storage-" + id)
    }
    public func storage(_ id: String) throws -> [String: String] {
        guard Self.validID(id) else { throw OrbitWidgetError("Invalid widget identifier.") }
        return try read("storage-" + id).map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
    public func output(_ id: String, family: String) throws -> OrbitWidgetOutput? {
        guard Self.validID(id), Self.families.contains(family) else { throw OrbitWidgetError("Invalid widget.") }
        return try read("output-" + id + "-" + family).map { try JSONDecoder().decode(OrbitWidgetOutput.self, from: $0) }
    }
    public func save(_ output: OrbitWidgetOutput, script: OrbitWidgetScript, family: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.families.contains(family), let current = try self.script(script.id), current.source == script.source else {
            throw OrbitWidgetError("The widget changed while it was refreshing. Try again.")
        }
        let storage = try JSONEncoder().encode(output.storage), data = try JSONEncoder().encode(output)
        guard storage.count <= 64 * 1024, output.storage.count <= 128, data.count <= 384 * 1024 else { throw OrbitWidgetError("This widget has saved too much data.") }
        try write(storage, key: "storage-" + script.id)
        try write(data, key: "output-" + script.id + "-" + family)
    }
    public static let families = ["small", "medium", "large", "circular", "rectangular", "inline"]
    private static func validID(_ id: String) -> Bool { !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) } }
}
