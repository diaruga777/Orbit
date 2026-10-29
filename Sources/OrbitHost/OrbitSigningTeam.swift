import Foundation
import Security
import LocalAuthentication

public struct OrbitSigningTeam: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

extension OrbitSetup {
    /// Xcode owns account authentication and provisioning. Read only public team
    /// metadata and certificate subjects, never account tokens or private keys.
    public func signingTeams() -> [OrbitSigningTeam] {
        let preferences = UserDefaults(suiteName: "com.apple.dt.Xcode")
        _ = preferences?.synchronize() // Reload after the user returns from Xcode Accounts.
        let caches = Self.xcodeTeamCacheKeys.reduce(into: [String: Any]()) { values, key in
            values[key] = preferences?.object(forKey: key)
        }
        let teams = Self.signingTeams(inXcodePreferences: caches)
        // Xcode can know the team before a development certificate exists. Do not
        // make account discovery depend on a Keychain identity/private-key lookup.
        if !teams.isEmpty { return teams }
        var certificateTeams: [OrbitSigningTeam] = []
        var items: CFTypeRef?
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecReturnRef: true,
                                    kSecMatchLimit: kSecMatchLimitAll, kSecUseAuthenticationContext: context]
        if SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess {
            for certificate in items as? [SecCertificate] ?? [] {
                guard let summary = SecCertificateCopySubjectSummary(certificate) as String?,
                      summary.hasPrefix("Apple Development:") || summary.hasPrefix("iPhone Developer:") else { continue }
                // The public certificate subject’s organizational unit holds the team ID.
                guard let values = SecCertificateCopyValues(certificate, [kSecOIDOrganizationalUnitName] as CFArray, nil) as? [CFString: Any],
                      let property = values[kSecOIDOrganizationalUnitName] as? [CFString: Any],
                      let id = property[kSecPropertyKeyValue] as? String, OrbitSetupState.validTeam(id),
                      !certificateTeams.contains(where: { $0.id == id }) else { continue }
                certificateTeams.append(.init(id: id, name: summary.replacingOccurrences(of: "Apple Development: ", with: "")))
            }
        }
        return certificateTeams.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let xcodeTeamCacheKeys = ["IDEProvisioningTeamManagerUserDefaultDictionary", "IDEProvisioningTeams", "IDEProvisioningTeamByIdentifier"]

    /// Only inspect team caches, not Xcode's account/session preferences. The
    /// identifier index takes precedence over older caches when names differ.
    nonisolated static func signingTeams(inXcodePreferences preferences: [String: Any]) -> [OrbitSigningTeam] {
        var teams: [String: OrbitSigningTeam] = [:]
        for key in xcodeTeamCacheKeys {
            for team in signingTeams(in: preferences[key] ?? [:]) { teams[team.id] = team }
        }
        return teams.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public nonisolated static func signingTeams(in value: Any) -> [OrbitSigningTeam] {
        var result: [String: OrbitSigningTeam] = [:]
        func visit(_ value: Any) {
            if let rows = value as? [Any] { rows.forEach(visit) }
            guard let row = value as? [String: Any] else { return }
            let id = (row["teamID"] ?? row["teamIdentifier"] ?? row["identifier"]) as? String
            let name = (row["teamName"] ?? row["name"]) as? String
            if let id, let name, OrbitSetupState.validTeam(id), !name.isEmpty {
                let personal = row["isFreeProvisioningTeam"] as? Bool == true
                result[id] = .init(id: id, name: name + (personal && !name.contains("Personal Team") ? " (Personal Team)" : ""))
            }
            row.values.forEach(visit)
        }
        visit(value)
        return result.values.sorted { $0.id < $1.id }
    }
}
