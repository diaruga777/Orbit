import Foundation
import CryptoKit
import OrbitCore
import OrbitMac

public enum OrbitSetupStep: String, CaseIterable, Codable, Sendable {
    case welcome, tools, access, account, phone, agents, install, connect, refresh, complete
    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .tools: return "Developer Tools"
        case .access: return "Mac Access"
        case .account: return "Apple Account"
        case .phone: return "Your iPhone"
        case .agents: return "AI Tools"
        case .install: return "Install Orbit"
        case .connect: return "Connect"
        case .refresh: return "Phone Refresh"
        case .complete: return "Ready"
        }
    }
    public var symbol: String {
        switch self {
        case .welcome: return "sparkles"
        case .tools: return "hammer"
        case .access: return "folder.badge.gearshape"
        case .account: return "person.crop.circle"
        case .phone: return "iphone"
        case .agents: return "terminal"
        case .install: return "arrow.down.app"
        case .connect: return "link"
        case .refresh: return "arrow.clockwise"
        case .complete: return "checkmark.circle"
        }
    }
}
public struct OrbitSetupState: Codable, Sendable {
    public var step: OrbitSetupStep = .welcome
    public var teamID = ""
    public var bundlePrefix = ""
    public var deviceID = ""
    public var folder: String?
    public var source: String?
    public var installTargetID: String?
    public var installJobID: String?
    public var installed = false
    public var agentChoice = "codex"
    public var agentConfigured = false
    public var finished = false
    public init() {}
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
    public init(root: URL) { self.root = root }
    public func load() throws -> OrbitSetupState {
        let url = root.appendingPathComponent("setup.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(OrbitSetupState.self, from: Data(contentsOf: url))
    }
    public func save(_ state: OrbitSetupState) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("setup.json"), options: .atomic)
    }
    public func checkTools() async -> OrbitToolReadiness {
        var result = OrbitToolReadiness()
        do {
            result.developerDirectory = String(decoding: try await OrbitCommand.run("/usr/bin/xcode-select", ["-p"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            result.xcode = result.developerDirectory.contains(".app/Contents/Developer")
            guard result.xcode else { result.detail = "Install the full Xcode app to build iPhone apps."; return result }
            _ = try await OrbitCommand.run("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"]); result.firstLaunch = true
            let sdk = String(decoding: try await OrbitCommand.run("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            result.iOSSDK = (Int(sdk.split(separator: ".").first ?? "") ?? 0) >= 26
            _ = try await OrbitCommand.run("/usr/bin/python3", ["--version"]); result.python = true
            result.detail = result.ready ? "Xcode and iOS \(sdk) tools are ready." : "Install iOS 26 or later in Xcode → Settings → Components."
        } catch { result.detail = error.localizedDescription }
        return result
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
        _ = try await OrbitCommand.run("/usr/bin/git", ["add", "--force", "Vendor/OrbitNet.xcframework", "Vendor/DeviceGateway/IDevice.xcframework"], directory: target)
        let staged = try await OrbitCommand.run("/usr/bin/git", ["status", "--porcelain", "--untracked-files=no"], directory: target)
        if !staged.isEmpty {
            _ = try await OrbitCommand.run("/usr/bin/git", ["-c", "user.name=Orbit Setup", "-c", "user.email=setup@localhost", "-c", "commit.gpgsign=false", "commit", "-m", "Install bundled Orbit phone source"], directory: target)
        }
        try Data("ready".utf8).write(to: target.appendingPathComponent(".orbit-source-ready"), options: .atomic)
        return target
    }
    public func exportMCP(app: URL) throws -> URL {
        let directory = root.appendingPathComponent("AgentSetup"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("orbit-mcp.json")
        let cli = app.appendingPathComponent("Contents/Resources/AgentTools/bin/orbit").path
        let object: [String: Any] = ["mcpServers": ["orbit": ["command": "/usr/bin/python3", "args": [cli, "mcp"], "env": ["ORBIT_HOME": root.path]]]]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        return file
    }
}
