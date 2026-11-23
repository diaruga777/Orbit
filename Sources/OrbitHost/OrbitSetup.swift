import Foundation
import CryptoKit
import OrbitCore
import OrbitMac

public enum OrbitSetupStep: String, CaseIterable, Codable, Sendable {
    // Old raw values remain decodable so interrupted setup can migrate.
    public static let allCases: [Self] = [.mac, .phone]
    case mac, phone, welcome, tools, access, account, agents, install, connect, refresh, complete

    public var current: Self {
        switch self {
        case .welcome, .tools, .access, .account, .agents, .mac: return .mac
        case .install, .connect, .refresh, .complete, .phone: return .phone
        }
    }
}
public struct OrbitSetupState: Codable, Sendable {
    public var step: OrbitSetupStep = .mac
    public var teamID = ""
    public var bundlePrefix = ""
    public var iosBundleID: String?
    public var deviceID = ""
    public var folder: String?
    public var source: String?
    public var installTargetID: String?
    public var installJobID: String?
    public var installed = false
    public var agentAssisted: Bool?
    public var folderApproved: Bool?
    public var finished = false
    public init() {
        folder = Self.defaultFolder.path
        bundlePrefix = "dev.orbit.u" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Orbit", isDirectory: true)
    }
    public static func validTeam(_ value: String) -> Bool { value.count == 10 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").contains($0) } }
    public static func validPrefix(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && value.count < 180 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) } }
    }
}
public struct OrbitToolReadiness: Sendable {
    public var xcode = false
    public var firstLaunch = false
    public var iOSSDK = false
    public var python = false
    public var developerDirectory = ""
    public var detail = ""
    public init() {}
    public var ready: Bool { xcode && firstLaunch && iOSSDK && python }
}

/// All mutation is triggered by setup actions, never by discovering a phone.
/// No Apple passwords or pairing keys are part of this state or these logs.
public actor OrbitSetup {
    public let root: URL
    private let canonicalSource: URL?
    public init(root: URL, canonicalSource: URL? = nil) {
        self.root = root; self.canonicalSource = canonicalSource ?? OrbitPhoneIdentity.canonicalSource
    }
    public func load() throws -> OrbitSetupState {
        let url = root.appendingPathComponent("setup.json")
        var state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(OrbitSetupState.self, from: Data(contentsOf: url)) : OrbitSetupState()
        state.step = state.step.current
        if state.folder == nil { state.folder = OrbitSetupState.defaultFolder.path }
        if state.bundlePrefix.isEmpty { state.bundlePrefix = OrbitSetupState().bundlePrefix }
        if let canonicalSource {
            let project = try OrbitPhoneIdentity.project(at: canonicalSource)
            if (state.iosBundleID ?? state.bundlePrefix + ".ios") != project.iosBundleID {
                state.installJobID = nil; state.installed = false
            }
            state.source = canonicalSource.path; state.bundlePrefix = project.bundlePrefix!
            state.teamID = project.developmentTeam!; state.iosBundleID = project.iosBundleID
        }
        return state
    }
    public func save(_ state: OrbitSetupState) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("setup.json"), options: .atomic)
    }
    /// Runs in the installed executable before its first window opens. The host
    /// holds the same single-writer lock and uses the same folder migration as the GUI.
    public func prepareForAgent(host: OrbitHost) async throws {
        var state = try load()
        guard !state.finished else { return }
        state.agentAssisted = true
        if state.installed || state.installJobID != nil {
            state.step = .phone
        } else {
            let roots = await host.configuration.allowedRoots
            let folder = roots.first ?? state.folder ?? OrbitSetupState.defaultFolder.path
            state.folder = folder
            state.folderApproved = false
            state.step = .mac
            do {
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                if roots.isEmpty { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
                _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
                if roots.isEmpty { _ = try await host.configureProjectsFolder(folder) }
                state.folderApproved = true
            } catch {
                // The wizard can request folder permission or choose another folder.
                try save(state)
                return
            }
            if state.teamID.isEmpty {
                let teams = signingTeams()
                if teams.count == 1 { state.teamID = teams[0].id }
            }
            let tools = await checkTools()
            if tools.ready && OrbitSetupState.validTeam(state.teamID) && OrbitSetupState.validPrefix(state.bundlePrefix) {
                state.step = .phone
            }
        }
        try save(state)
    }

    public nonisolated static var pythonExecutable: String {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }
    public func checkTools() async -> OrbitToolReadiness {
        var result = OrbitToolReadiness()
        do {
            result.developerDirectory = try CodeXcodeTools.developerDirectory()
            result.xcode = result.developerDirectory.contains(".app/Contents/Developer")
            guard result.xcode else { result.detail = "Install the full Xcode app to build iPhone apps."; return result }
            _ = try await OrbitCommand.run("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"]); result.firstLaunch = true
            let sdk = String(decoding: try await OrbitCommand.run("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            result.iOSSDK = (Int(sdk.split(separator: ".").first ?? "") ?? 0) >= 26
            _ = try await OrbitCommand.run(Self.pythonExecutable, ["--version"]); result.python = true
            result.detail = result.ready ? "Xcode and iOS \(sdk) tools are ready." : "Install iOS 26 or later in Xcode → Settings → Components."
        } catch { result.detail = error.localizedDescription }
        return result
    }
    public func recommendedXcode() async throws -> String {
        let request = URLRequest(url: URL(string: "https://xcodereleases.com/data.json")!, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1024 * 1024 else {
            throw CodeFailure("Couldn’t check Xcode downloads. Try again in a moment.")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return try Self.recommendedXcode(in: data, macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
    /// Uses the same public release metadata as xcodes; all remote version text
    /// is validated before becoming an installer argument. Betas are excluded.
    public nonisolated static func recommendedXcode(in data: Data, macOSVersion: String) throws -> String {
        func numericVersion(_ value: String) -> Bool {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            return (2...3).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        }
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        let versions = rows.compactMap { row -> String? in
            guard let version = row["version"] as? [String: Any],
                  let release = version["release"] as? [String: Any], release["release"] as? Bool == true,
                  let number = version["number"] as? String, numericVersion(number),
                  let minimum = row["requires"] as? String, numericVersion(minimum),
                  number.compare("26.2", options: .numeric) != .orderedAscending,
                  minimum.compare(macOSVersion, options: .numeric) != .orderedDescending else { return nil }
            return number
        }
        guard let version = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else {
            throw CodeFailure("Update macOS to install the Xcode version Orbit needs, then try again.")
        }
        return version
    }
    public func devices() async throws -> [CodeDevice] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try await CodeDeviceSupport.devicesForSetup(root: root)
    }
    public func phoneReady(_ device: String) async throws -> Bool {
        guard !device.isEmpty, device.count <= 128 else { return false }
        let output = root.appendingPathComponent("device-check-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await OrbitCommand.run("/usr/bin/xcrun", ["devicectl", "device", "info", "details", "--device", device, "--json-output", output.path])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any] ?? [:]
        return Self.phoneReady(object, expected: device)
    }
    public nonisolated static func phoneReady(_ object: [String: Any], expected: String) -> Bool {
        let result = object["result"] as? [String: Any] ?? [:]
        let properties = result["deviceProperties"] as? [String: Any] ?? (result["properties"] as? [String: Any])?["device"] as? [String: Any] ?? [:]
        let hardware = result["hardwareProperties"] as? [String: Any] ?? (result["properties"] as? [String: Any])?["hardware"] as? [String: Any] ?? [:]
        return hardware["udid"] as? String == expected && hardware["reality"] as? String == "physical" && properties["developerModeStatus"] as? String == "enabled"
    }
    public func prepareSource(bundle: Bundle = .main) async throws -> URL {
        if let canonicalSource {
            _ = try OrbitPhoneIdentity.project(at: canonicalSource)
            return canonicalSource
        }
        guard let archive = bundle.url(forResource: "OrbitPhoneSource", withExtension: "zip"),
              let manifest = bundle.url(forResource: "OrbitPhoneSource", withExtension: "json") else {
            // Source builds can use an explicit checkout; a distributed DMG must
            // contain the authenticated payload instead of cloning at runtime.
            if let checkout = ProcessInfo.processInfo.environment["ORBIT_CHECKOUT"], checkout.hasPrefix("/"), FileManager.default.fileExists(atPath: checkout + "/Orbit.xcodeproj/project.pbxproj") { return URL(fileURLWithPath: checkout) }
            throw CodeFailure("This copy of Orbit is missing its iPhone installer. Download a complete Orbit DMG.")
        }
        struct Manifest: Decodable { var sha256: String; var revision: String }
        let info = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
        guard (40...64).contains(info.revision.count), info.revision.allSatisfy({ $0.isHexDigit }) else { throw CodeFailure("Invalid phone source manifest.") }
        let handle = try FileHandle(forReadingFrom: archive); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == info.sha256 else { throw CodeFailure("The phone installer failed its integrity check. Download Orbit again.") }
        let target = root.appendingPathComponent("PhoneSource/" + info.revision, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.appendingPathComponent(".orbit-source-ready").path) { return target }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try await OrbitCommand.run("/usr/bin/ditto", ["-x", "-k", archive.path, target.path])
        _ = try await OrbitCommand.run("/usr/bin/git", ["init", "--initial-branch=main"], directory: target)
        _ = try await OrbitCommand.run("/usr/bin/git", ["add", "."], directory: target)
        _ = try await OrbitCommand.run("/usr/bin/git", ["add", "--force", "Vendor/OrbitNet.xcframework", "Vendor/DeviceGateway/IDevice.xcframework", "Vendor/IrohDirect"], directory: target)
        let staged = try await OrbitCommand.run("/usr/bin/git", ["status", "--porcelain", "--untracked-files=no"], directory: target)
        if !staged.isEmpty {
            _ = try await OrbitCommand.run("/usr/bin/git", ["-c", "user.name=Orbit Setup", "-c", "user.email=setup@localhost", "-c", "commit.gpgsign=false", "commit", "-m", "Install bundled Orbit phone source"], directory: target)
        }
        try Data("ready".utf8).write(to: target.appendingPathComponent(".orbit-source-ready"), options: .atomic)
        return target
    }
    public func configureSource(_ source: URL, state: OrbitSetupState) throws {
        // Only the wizard's private extracted snapshot is configured here.
        // An existing developer checkout owns its ignored identity already.
        guard source.standardizedFileURL.path.hasPrefix(root.appendingPathComponent("PhoneSource").standardizedFileURL.path + "/") else { return }
        guard OrbitSetupState.validTeam(state.teamID), OrbitSetupState.validPrefix(state.bundlePrefix) else { throw CodeFailure("Choose your Apple Account first.") }
        let file = source.appendingPathComponent("Config/Local.xcconfig")
        var bundle = state.iosBundleID ?? state.bundlePrefix + ".ios"
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try CodeOrbitIdentity.resolve(CodeProject(path: source.appendingPathComponent("Orbit.xcodeproj").path))
            guard existing.bundlePrefix == state.bundlePrefix else { throw CodeFailure("Keep Orbit’s existing bundle prefix to preserve phone data.") }
            bundle = existing.iosBundleID ?? bundle
        }
        // Account changes update the team while preserving the phone identity.
        let config = try CodeOrbitIdentity.localConfiguration(bundlePrefix: state.bundlePrefix, developmentTeam: state.teamID, iosBundleID: bundle)
        try Data(config.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Older bundled installs kept signing identity only in setup and the catalog.
    /// Restore their missing ignored file only when all saved identities agree.
    func restoreLegacyIdentity(for project: CodeProject, phoneBundleID: String?) throws {
        let source = URL(fileURLWithPath: project.root).resolvingSymlinksInPath()
        let privateRoot = root.appendingPathComponent("PhoneSource").resolvingSymlinksInPath()
        guard URL(fileURLWithPath: project.path).lastPathComponent == "Orbit.xcodeproj",
              source.path.hasPrefix(privateRoot.path + "/"),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("Config/Orbit.xcconfig").path) else { return }
        let file = source.appendingPathComponent("Config/Local.xcconfig")
        // Even an invalid existing config belongs to the user; the build reports it.
        guard !FileManager.default.fileExists(atPath: file.path),
              (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        let saved = root.appendingPathComponent("setup.json")
        guard FileManager.default.fileExists(atPath: saved.path) else { return }
        let state = try JSONDecoder().decode(OrbitSetupState.self, from: Data(contentsOf: saved))
        guard let original = state.source,
              URL(fileURLWithPath: original).resolvingSymlinksInPath().path == source.path else { return }
        let bundle = project.iosBundleID ?? state.bundlePrefix + ".ios"
        guard project.bundlePrefix == state.bundlePrefix, project.developmentTeam == state.teamID,
              phoneBundleID == bundle else {
            throw CodeFailure("Orbit’s saved signing details don’t match. Open setup on your Mac before building.")
        }
        let config = try CodeOrbitIdentity.localConfiguration(bundlePrefix: state.bundlePrefix,
            developmentTeam: state.teamID, iosBundleID: bundle)
        // Resolve Config too: a symlink must not turn recovery into an outside write.
        guard file.deletingLastPathComponent().resolvingSymlinksInPath().path == source.appendingPathComponent("Config").path else { return }
        try Data(config.utf8).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func exportMCP(app: URL) throws -> URL {
        let directory = root.appendingPathComponent("AgentSetup"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("orbit-mcp.json")
        let cli = app.appendingPathComponent("Contents/Resources/AgentTools/bin/orbit").path
        let object: [String: Any] = ["mcpServers": ["orbit": ["command": Self.pythonExecutable, "args": [cli, "mcp"], "env": ["ORBIT_HOME": root.path]]]]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        return file
    }
}
