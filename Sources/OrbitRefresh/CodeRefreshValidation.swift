import Foundation
import SideSign
import OrbitCore

enum CodeRefreshValidation {
    static func certificate(_ value: X509Certificate, teamID: String, now: Date = Date()) throws {
        guard value.organizationalUnit == teamID else { throw CodeFailure("This certificate belongs to another Apple team. Choose a certificate for your selected team.") }
        guard let start = value.notBefore, let end = value.notAfter, start <= now, end > now else {
            throw CodeFailure("This certificate has expired or isn’t valid yet. Import an active certificate or create one.")
        }
    }
    static func preserveIdentity(previous: ProvisioningProfile, renewed: ProvisioningProfile) throws {
        guard previous.bundleIdentifier == renewed.bundleIdentifier, previous.teamIdentifier == renewed.teamIdentifier else { throw CodeFailure("The refreshed profile changed this app’s identity.") }
        for key in ["application-identifier", "keychain-access-groups", "com.apple.security.application-groups", "com.apple.developer.icloud-container-identifiers", "com.apple.developer.ubiquity-kvstore-identifier", "com.apple.developer.associated-domains"] {
            guard let old = previous.entitlements[key] else { continue }
            guard let new = renewed.entitlements[key], NSDictionary(dictionary: [key: old]).isEqual(to: [key: new]) else {
                throw CodeFailure("The refreshed profile doesn’t preserve this app’s capabilities. Check signing on the Mac before refreshing.")
            }
        }
    }
    static func preserveSignedEntitlements(previous: [String: any Sendable], renewed: [String: any Sendable]) throws {
        guard NSDictionary(dictionary: previous).isEqual(to: renewed) else {
            throw CodeFailure("Signing changed this app’s capabilities. Refresh from your Mac to keep its data and access.")
        }
    }
}
