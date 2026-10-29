import Foundation
import OrbitCore
#if os(macOS)
import AppKit
#endif

/// Resolve one full Xcode for discovery, signing checks and deployment without
/// changing the user's system-wide command-line tools selection.
public enum CodeXcodeTools {
    public static func developerDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let selection = Process()
        let pipe = Pipe()
        selection.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        selection.arguments = ["-p"]
        selection.standardOutput = pipe; selection.standardError = FileHandle.nullDevice
        try selection.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        selection.waitUntilExit()
        let selected = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [URL] = []
        #if os(macOS)
        // When standalone tools are selected, prefer the Xcode the user has open.
        candidates += NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.dt.Xcode" }.compactMap(\.bundleURL)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") { candidates.append(app) }
        #endif
        for directory in [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            candidates += ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }.filter { Bundle(url: $0)?.bundleIdentifier == "com.apple.dt.Xcode" }
        }
        return try resolve(explicit: environment["DEVELOPER_DIR"], selected: selected, applications: candidates)
    }

    static func resolve(explicit: String?, selected: String, applications: [URL]) throws -> String {
        func developer(_ path: String) -> String? {
            guard path.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: path)
            let directory = url.pathExtension == "app" ? url.appendingPathComponent("Contents/Developer") : url
            guard directory.path.hasSuffix(".app/Contents/Developer"),
                  FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("usr/bin/xcodebuild").path) else { return nil }
            return directory.path
        }
        if let explicit, !explicit.isEmpty {
            guard let directory = developer(explicit) else { throw CodeFailure("Orbit’s Xcode override is unavailable. Choose an installed Xcode and reopen Orbit.") }
            return directory
        }
        if let directory = developer(selected) { return directory }
        for app in applications { if let directory = developer(app.path) { return directory } }
        throw CodeFailure("Open the full Xcode app, then try again. Orbit needs Xcode’s iPhone tools.")
    }

    public static func environment(for executable: String, inheriting environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        guard ["/usr/bin/xcrun", "/usr/bin/xcodebuild", "/usr/bin/swift", "/usr/bin/swiftc"].contains(executable) else { return environment }
        var result = environment
        result["DEVELOPER_DIR"] = try developerDirectory(environment: environment)
        return result
    }
}
