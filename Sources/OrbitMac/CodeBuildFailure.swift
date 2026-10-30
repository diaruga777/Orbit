import Foundation

/// Turn known Xcode signing failures into recovery steps without copying account
/// names, paths or arbitrary repository output into the public job summary.
enum CodeBuildFailure {
    static let fallback = "The build stopped. See the Mac job log for details."

    static func message(log: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return fallback }
        defer { try? handle.close() }
        // Account warnings appear near startup; signing errors appear near the
        // end. Read both with a fixed memory bound even for very large logs.
        guard let size = try? handle.seekToEnd() else { return fallback }
        let limit: UInt64 = 64 * 1024
        try? handle.seek(toOffset: 0)
        var data = (try? handle.read(upToCount: Int(min(size, limit)))) ?? Data()
        if size > limit {
            try? handle.seek(toOffset: size > limit * 2 ? size - limit : limit)
            data.append(10)
            data.append((try? handle.read(upToCount: Int(limit))) ?? Data())
        }
        return message(output: String(decoding: data, as: UTF8.self))
    }

    static func message(output: String) -> String {
        let errors = output.lowercased().components(separatedBy: .newlines).filter { $0.contains("error:") }
        let profileMismatch = errors.contains {
            $0.contains("provisioning profile") &&
            ($0.contains("doesn't include") || $0.contains("does not include") || $0.contains("doesn't support"))
        }
        let accountFailure = errors.contains {
            $0.contains("no accounts") || $0.contains("no account for team") ||
            $0.contains("authentication credentials") || $0.contains("session has expired")
        }
        var messages: [String] = []
        if accountFailure {
            messages.append("Xcode couldn’t use your signing account. On your Mac, open Xcode → Settings → Accounts and sign in again, then retry.")
        }
        if profileMismatch {
            if errors.contains(where: { $0.contains("time sensitive notifications") || $0.contains("com.apple.developer.usernotifications.time-sensitive") }) {
                messages.append("The app’s provisioning profile is missing Time Sensitive Notifications. In the source project’s Signing & Capabilities, check the selected team and refresh automatic signing with an account that supports this capability.")
            } else {
                messages.append("The app’s provisioning profile is missing a required capability. In the source project’s Signing & Capabilities, check the selected team and refresh signing with an account that supports the app’s capabilities.")
            }
        }
        return messages.isEmpty ? fallback : messages.joined(separator: "\n\n")
    }
}
