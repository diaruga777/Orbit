import Foundation
import OrbitCore

/// Personal Team refreshes must request a fresh profile, rather than repeatedly
/// installing a newly compiled app with yesterday's expiring profile. Only
/// matching, expiring automatic-signing cache entries are temporarily moved.
struct CodeProfileRefresh {
    struct Entry: Codable { var original: String; var backup: String }
    let directory: URL
    let entries: [Entry]
    static var caches: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"), home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles")]
    }
    static func matches(_ profile: [String: Any], bundle: String, team: String, device: String, minimumHours: Int, at date: Date) -> Bool {
        guard let expiry = profile["ExpirationDate"] as? Date, expiry <= date.addingTimeInterval(Double(minimumHours) * 3600),
              (profile["TeamIdentifier"] as? [String])?.contains(team) == true,
              (profile["ProvisionedDevices"] as? [String])?.contains(device) == true,
              let entitlements = profile["Entitlements"] as? [String: Any], entitlements["get-task-allow"] as? Bool == true,
              let application = entitlements["application-identifier"] as? String else { return false }
        let prefix = team + "."
        guard application.hasPrefix(prefix) else { return false }
        let identifier = String(application.dropFirst(prefix.count))
        if identifier.hasSuffix("*") { return bundle.hasPrefix(String(identifier.dropLast())) }
        return identifier == bundle || identifier.hasPrefix(bundle + ".")
    }
    static func prepare(project: CodeProject, settings: [String: String], device: String, root: URL, process: CodeProcess) async throws -> Self? {
        guard let hours = project.minimumProfileHours, hours > 0, settings["CODE_SIGN_STYLE"] == "Automatic",
              let bundle = settings["PRODUCT_BUNDLE_IDENTIFIER"], let team = CodeDeviceSigning.team(settings) else { return nil }
        let directory = root.appendingPathComponent("ProfileRefresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var entries: [Entry] = []
        do {
            for cache in caches {
                for file in ((try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []).prefix(2000) where file.pathExtension == "mobileprovision" {
                    let decoded = directory.appendingPathComponent("decoded.plist"), log = directory.appendingPathComponent("decode.log")
                    guard try await process.run("/usr/bin/security", ["cms", "-D", "-i", file.path, "-o", decoded.path], directory: directory.path, log: log, timeout: 15) == 0,
                          let data = try? Data(contentsOf: decoded), let profile = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          matches(profile, bundle: bundle, team: team, device: device, minimumHours: hours, at: Date()) else { continue }
                    let backup = directory.appendingPathComponent(UUID().uuidString + ".mobileprovision")
                    // Journal before moving so an interrupted build can restore
                    // cached profiles on the next Orbit launch.
                    entries.append(Entry(original: file.path, backup: backup.path))
                    try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
                    try FileManager.default.moveItem(at: file, to: backup)
                }
            }
            return Self(directory: directory, entries: entries)
        } catch { Self(directory: directory, entries: entries).restore(); throw error }
    }
    func restore() {
        var pending = false
        for entry in entries {
            let original = URL(fileURLWithPath: entry.original), backup = URL(fileURLWithPath: entry.backup)
            guard Self.caches.contains(where: { original.deletingLastPathComponent().standardizedFileURL == $0.standardizedFileURL }),
                  backup.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { continue }
            if !FileManager.default.fileExists(atPath: original.path), FileManager.default.fileExists(atPath: backup.path) {
                do { try FileManager.default.moveItem(at: backup, to: original) } catch { pending = true }
            }
        }
        if !pending { try? FileManager.default.removeItem(at: directory) }
    }
    static func recover(root: URL) {
        for directory in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where directory.lastPathComponent.hasPrefix("ProfileRefresh-") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { continue }
            Self(directory: directory, entries: entries).restore()
        }
    }
    static func verify(app: URL, minimumHours: Int?, root: URL, process: CodeProcess) async throws {
        guard let hours = minimumHours else { return }
        let products = [app] + ((try? FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "appex" }
        for product in products {
            let decoded = root.appendingPathComponent(UUID().uuidString + ".plist"), log = root.appendingPathComponent(UUID().uuidString + ".log")
            defer { try? FileManager.default.removeItem(at: decoded); try? FileManager.default.removeItem(at: log) }
            guard try await process.run("/usr/bin/security", ["cms", "-D", "-i", product.appendingPathComponent("embedded.mobileprovision").path, "-o", decoded.path], directory: root.path, log: log, timeout: 20) == 0,
                  let profile = try PropertyListSerialization.propertyList(from: Data(contentsOf: decoded), format: nil) as? [String: Any],
                  let expiry = profile["ExpirationDate"] as? Date, expiry > Date().addingTimeInterval(Double(hours) * 3600) else {
                throw CodeFailure("Xcode did not renew this app’s development profile far enough ahead for its refresh schedule. Open Signing & Capabilities in Xcode with your Personal Team, refresh signing, then retry. Orbit has kept the previous app installed.")
            }
        }
    }
}
