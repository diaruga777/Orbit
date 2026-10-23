import Foundation
import Security

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
        var teams = Self.signingTeams(in: preferences?.dictionary(forKey: "IDEProvisioningTeamManagerUserDefaultDictionary") ?? [:])
        var items: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll]
        if SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess {
            for identity in items as? [SecIdentity] ?? [] {
                var certificate: SecCertificate?
                guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                      let summary = SecCertificateCopySubjectSummary(certificate) as String?,
                      summary.hasPrefix("Apple Development:") || summary.hasPrefix("iPhone Developer:") else { continue }
                // Development identity names end with the public ten-character team ID.
                guard let values = SecCertificateCopyValues(certificate, [kSecOIDOrganizationalUnitName] as CFArray, nil) as? [CFString: Any],
                      let property = values[kSecOIDOrganizationalUnitName] as? [CFString: Any],
                      let id = property[kSecPropertyKeyValue] as? String, OrbitSetupState.validTeam(id),
                      !teams.contains(where: { $0.id == id }) else { continue }
                teams.append(.init(id: id, name: summary.replacingOccurrences(of: "Apple Development: ", with: "")))
            }
        }
        return teams.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
