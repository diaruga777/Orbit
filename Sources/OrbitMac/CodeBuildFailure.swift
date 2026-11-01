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
        let expiredSession = errors.contains { $0.contains("session has expired") }
        let accountFailure = errors.contains {
            $0.contains("no accounts") || $0.contains("no account for team") ||
            $0.contains("authentication credentials")
        }
        var messages: [String] = []
        // Lead with the concrete provisioning failure. “No Accounts” can mean
        // xcodebuild cannot provision a target, even with an account in Xcode.
        if profileMismatch {
            let profileErrors = errors.filter { $0.contains("provisioning profile") }
            if profileErrors.contains(where: { $0.contains("app groups") || $0.contains("com.apple.security.application-groups") }) {
                messages.append("The app or an extension needs an App Groups provisioning profile. On your Mac, open its Signing & Capabilities in Xcode and refresh automatic signing for the selected team.")
            }
            if profileErrors.contains(where: { $0.contains("time sensitive notifications") || $0.contains("com.apple.developer.usernotifications.time-sensitive") }) {
                messages.append("The app’s provisioning profile is missing Time Sensitive Notifications. On your Mac, refresh its automatic signing in Xcode → Signing & Capabilities.")
            }
            if messages.isEmpty {
                messages.append("The app or an extension has a provisioning profile that’s missing a required capability. On your Mac, check its team and refresh signing in Xcode → Signing & Capabilities.")
            }
        }
        if expiredSession {
            messages.append("Xcode reports that its signing session expired. On your Mac, open Xcode → Settings → Accounts and sign in again, then retry.")
        } else if accountFailure {
            let missingToken = output.lowercased().components(separatedBy: .newlines).contains {
                $0.contains("dvtdeveloperaccountmanager") && $0.contains("missing xcode-token")
            }
            if missingToken {
                messages.append("Xcode’s build tools couldn’t load the saved signing session. Your account may still appear signed in. On your Mac, check the account and selected team in Xcode → Settings → Accounts, then retry.")
            } else {
                messages.append("Xcode couldn’t provision this build with the selected team. On your Mac, check the team for the app and its extensions in Signing & Capabilities and Xcode → Settings → Accounts.")
            }
        }
        return messages.isEmpty ? fallback : messages.joined(separator: "\n\n")
    }
}
