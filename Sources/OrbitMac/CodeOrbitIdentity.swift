import Foundation
import OrbitCore

/// Carry the user's ignored Orbit identity into a committed detached checkout.
/// Other apps retain their own signing and bundle settings.
public enum CodeOrbitIdentity {
    public static func isOrbit(_ project: CodeProject) -> Bool {
        URL(fileURLWithPath: project.path).lastPathComponent == "Orbit.xcodeproj" &&
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: project.root).appendingPathComponent("Config/Orbit.xcconfig").path)
    }
    public static func verify(bundleID: String, project: CodeProject, phoneBundleID: String? = nil, monitorBundleID: String? = nil) throws {
        if isOrbit(project), [phoneBundleID, monitorBundleID].compactMap({ $0 }).contains(where: { !$0.isEmpty && $0 != bundleID }) {
            throw CodeFailure("This build would install a different Orbit app. Reopen Orbit Mac and try again from your original Orbit app.")
        }
        if let expected = project.iosBundleID, expected != bundleID {
            throw CodeFailure("This Orbit revision doesn’t use your configured phone bundle ID. Update the selected branch before building it.")
        }
    }
    public static func resolve(_ project: CodeProject) throws -> CodeProject {
        let root = URL(fileURLWithPath: project.root)
        guard isOrbit(project) else { return project }
        let file = root.appendingPathComponent("Config/Local.xcconfig")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw CodeFailure("Set Orbit’s identity in Config/Local.xcconfig on your Mac before building.")
        }
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "//")[0].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        let prefix = values["ORBIT_BUNDLE_PREFIX"] ?? ""
        let team = values["DEVELOPMENT_TEAM"] ?? ""
        let bundle = values["ORBIT_IOS_BUNDLE_IDENTIFIER"] ?? prefix + ".ios"
        _ = try localConfiguration(bundlePrefix: prefix, developmentTeam: team, iosBundleID: bundle)
        var value = project
        value.bundlePrefix = prefix; value.developmentTeam = team; value.iosBundleID = bundle
        return value
    }
    /// Validate saved setup identity before restoring an older private source snapshot.
    public static func localConfiguration(bundlePrefix prefix: String, developmentTeam team: String, iosBundleID bundle: String) throws -> String {
        func validID(_ value: String) -> Bool {
            value.split(separator: ".", omittingEmptySubsequences: false).count >= 3 &&
            value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } } &&
            !["org.example.", "com.yourname."].contains(where: value.hasPrefix)
        }
        guard validID(prefix), validID(bundle), team.count == 10, team != "YOUR_TEAM_ID",
              team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw CodeFailure("Replace the sample bundle prefix and development team in Config/Local.xcconfig before building Orbit.")
        }
        return "ORBIT_BUNDLE_PREFIX = \(prefix)\nDEVELOPMENT_TEAM = \(team)\nORBIT_IOS_BUNDLE_IDENTIFIER = \(bundle)\n"
    }
}
