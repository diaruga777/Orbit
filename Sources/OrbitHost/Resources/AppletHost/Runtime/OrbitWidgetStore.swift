import Foundation
import Security

/// Shared keychain storage also works without a paid App Group capability.
/// The app and extension explicitly share the containing app's keychain group.
/// Scripts and their K-V state never synchronize through iCloud Keychain.
public final class OrbitWidgetStore: @unchecked Sendable {
    private let directory: URL?
    private let group: String?
    private let applets: Bool
    private var service: String { applets ? "Orbit.Applets.v1" : "Orbit.Widgets.v1" }
    private let lock = NSRecursiveLock()
    var executionScope: String { directory?.path ?? (group ?? "default") }
    public init(directory: URL? = nil, accessGroup: String? = nil, applets: Bool = false) {
        self.directory = applets ? directory?.appendingPathComponent("Applets") : directory; self.applets = applets
        group = accessGroup ?? Bundle.main.object(forInfoDictionaryKey: "OrbitWidgetKeychainGroup") as? String
    }
    private func read(_ key: String) throws -> Data? {
        if let directory { return try? Data(contentsOf: directory.appendingPathComponent(key)) }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
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
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
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
        let script = try applets ? OrbitAppletDefinition.widgetScript(source) : OrbitWidgetScript(source: source)
        var ids = try identifiers()
        guard ids.contains(script.id) || ids.count < 24 else { throw OrbitWidgetError("Remove a widget before adding another.") }
        // Every update is reviewed by the caller, including changes in domains.
        try write(JSONEncoder().encode(script), key: "script-" + script.id)
        for family in Self.families { try write(nil, key: "output-" + script.id + "-" + family) }
        if !ids.contains(script.id) { ids.append(script.id) }
        try write(JSONEncoder().encode(ids), key: "index")
        try clearPending(source)
    }
    public func remove(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.validID(id) else { throw OrbitWidgetError("Invalid widget identifier.") }
        try write(JSONEncoder().encode(identifiers().filter { $0 != id }), key: "index")
        try write(nil, key: "script-" + id)
        for family in Self.families { try write(nil, key: "output-" + id + "-" + family) }
        try write(nil, key: "storage-" + id)
        try write(nil, key: "applet-state-" + id)
    }
    /// Unapproved Mac source is persisted separately from executable scripts and private K-V data.
    public func pendingScripts() throws -> [OrbitWidgetScript] {
        lock.lock(); defer { lock.unlock() }
        return try read("pending").map { try JSONDecoder().decode([OrbitWidgetScript].self, from: $0) } ?? []
    }
    public func receive(_ sources: [String], origin: String) throws {
        lock.lock(); defer { lock.unlock() }
        let oldOrigin = try read("pending-origin").map { String(decoding: $0, as: UTF8.self) }
        let dismissed = oldOrigin == origin ? try dismissedScripts() : [:]
        var pending: [OrbitWidgetScript] = [], seen = Set<String>()
        for source in sources.prefix(24) {
            let candidate = try applets ? OrbitAppletDefinition.widgetScript(source) : OrbitWidgetScript(source: source)
            guard seen.insert(candidate.id).inserted else { continue }
            if try script(candidate.id)?.source == source { continue }
            if dismissed[candidate.id] == OrbitWidgetDefinition.digest(source) { continue }
            pending.append(candidate)
        }
        // Validate the entire snapshot before replacing the last successfully received queue.
        try write(JSONEncoder().encode(pending), key: "pending")
        if oldOrigin != origin { try write(nil, key: "dismissed") }
        try write(Data(origin.utf8), key: "pending-origin")
    }
    private func dismissedScripts() throws -> [String: String] {
        try read("dismissed").map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
    public func dismissPending(_ source: String) throws {
        lock.lock(); defer { lock.unlock() }
        let candidate = try applets ? OrbitAppletDefinition.widgetScript(source) : OrbitWidgetScript(source: source)
        var dismissed = try dismissedScripts()
        // Bound remembered dismissals; a new source digest is always offered for review.
        if dismissed.count >= 24, dismissed[candidate.id] == nil { dismissed = [:] }
        dismissed[candidate.id] = OrbitWidgetDefinition.digest(source)
        try write(JSONEncoder().encode(dismissed), key: "dismissed")
        try clearPending(source)
    }
    public func approvePending(_ source: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard try pendingScripts().contains(where: { $0.source == source }) else {
            throw OrbitWidgetError("This file changed on your Mac. Review the latest copy.")
        }
        try install(source)
        try clearPending(source)
    }
    private func clearPending(_ source: String) throws {
        try write(JSONEncoder().encode(pendingScripts().filter { $0.source != source }), key: "pending")
    }
    public func storage(_ id: String) throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard Self.validID(id) else { throw OrbitWidgetError("Invalid widget identifier.") }
        if applets, let state = try appletState(id) { return state.storage }
        return try read("storage-" + id).map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
    private struct AppletState: Codable {
        var storage: [String: String]
        var polling: OrbitAppletPollState?
    }
    private func appletState(_ id: String) throws -> AppletState? {
        try read("applet-state-" + id).map { try JSONDecoder().decode(AppletState.self, from: $0) }
    }
    public func pollingState(_ id: String) throws -> OrbitAppletPollState? {
        lock.lock(); defer { lock.unlock() }
        guard applets, Self.validID(id) else { throw OrbitWidgetError("Invalid applet.") }
        return try appletState(id)?.polling
    }
    /// Storage and the notification outbox commit together, after source readback.
    public func savePolling(_ state: OrbitAppletPollState, storage: [String: String], script: OrbitWidgetScript) throws {
        lock.lock(); defer { lock.unlock() }
        guard applets, try self.script(script.id)?.source == script.source,
              storage.count <= 128, try JSONEncoder().encode(storage).count <= 64 * 1024 else {
            throw OrbitWidgetError("The applet changed while checking. Try again.")
        }
        try write(JSONEncoder().encode(AppletState(storage: storage, polling: state)), key: "applet-state-" + script.id)
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
        try write(data, key: "output-" + script.id + "-" + family)
        if applets {
            let state = AppletState(storage: output.storage, polling: try appletState(script.id)?.polling)
            try write(JSONEncoder().encode(state), key: "applet-state-" + script.id)
        } else { try write(storage, key: "storage-" + script.id) }
    }
    public static let families = ["small", "medium", "large", "circular", "rectangular", "inline"]
    private static func validID(_ id: String) -> Bool { !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) } }
}
