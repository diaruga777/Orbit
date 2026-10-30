import XCTest
import SideSign
@testable import OrbitRefresh

final class CodeRefreshValidationTests: XCTestCase {
    func testCertificateRejectsOtherTeamsAndExpiredOrFutureDates() throws {
        let cert = try XCTUnwrap(X509Certificate(data: Data(base64Encoded: "MIIC3jCCAcYCCQDgl3yfQd0MXDANBgkqhkiG9w0BAQsFADAxMRwwGgYDVQQDDBNPcmJpdCBJbmVydCBGaXh0dXJlMREwDwYDVQQLDAhURVNUVEVBTTAeFw0yNjEwMzAwODQ0MTFaFw0yNjExMjkwODQ0MTFaMDExHDAaBgNVBAMME09yYml0IEluZXJ0IEZpeHR1cmUxETAPBgNVBAsMCFRFU1RURUFNMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtMhczjT6pKXAIhfsRJoZ3pwRQvn/2ruTwd3F/bTZ1/a62OoRbi3ouEuXTL+Y6xji0mQ8CzgSiZIPd7s9MpZ9VhEnXo1R5Yq7b82XKABnAKSfvfZAWrNFh+m6FHy3ZEzrVLDnH7fYM0zfZnCytPKWLe5PEVTSKpSPR3y2iVcOnKokI1n0fx3U8MSFXe8oRMJoGN8cfA4ML6BWFIyjcqhw19Yb2p46lf/evFfOW88gN4gcizTPOu6Ak9E2egjH4sA+KDF3yqbNv3qPFAlLCsRwOEXABMcfb40bXD/eEPsn9GSIu06B3Z5eQyjvIYhkNMbIh4jDmQCh5VLG3a3bDMgutQIDAQABMA0GCSqGSIb3DQEBCwUAA4IBAQAGKp6j8DV84lmhWy7iC5UFiGoI2HBlZMLdU51ola1DfCerqIFy4Mypmn+QtwPVZVx7CTdAXlL/Y79jkV7Lp4bUfqRGfFUv1mLnVMcxOTpuVQO4P/1hhSgTcWGcQCLx2u31RPAZFYMDNtTzlBByM+mTprArGKLDWu/7yLH0F3rdyzliKzSivzwrS6qro1U1a4VeRbH2ECHNuq0+0yC/VKmU1gPlmXLZVaIDNtB+ZOeujAc9Yx1QgW69Nqgt8waDFIJMWmCosTM+FXMSueV7B0yOBoBP6sS1pn5vimKeoXmmLc/F246LRiHlMiGVKfCs8QsmJNzbfVyToW2jmJxuCR/d")!))
        let start = try XCTUnwrap(cert.notBefore), end = try XCTUnwrap(cert.notAfter)
        XCTAssertNoThrow(try CodeRefreshValidation.certificate(cert, teamID: "TESTTEAM", now: start.addingTimeInterval(1)))
        XCTAssertThrowsError(try CodeRefreshValidation.certificate(cert, teamID: "OTHER", now: start.addingTimeInterval(1)))
        XCTAssertThrowsError(try CodeRefreshValidation.certificate(cert, teamID: "TESTTEAM", now: start.addingTimeInterval(-1)))
        XCTAssertThrowsError(try CodeRefreshValidation.certificate(cert, teamID: "TESTTEAM", now: end))
    }
    func testSignedCapabilitiesMustSurviveExactlyIncludingSharedKeychain() throws {
        let original: [String: any Sendable] = ["application-identifier": "TESTTEAM.example.app", "keychain-access-groups": ["TESTTEAM.example.app"], "get-task-allow": true]
        XCTAssertNoThrow(try CodeRefreshValidation.preserveSignedEntitlements(previous: original, renewed: original))
        for key in original.keys {
            var removed = original; removed.removeValue(forKey: key)
            XCTAssertThrowsError(try CodeRefreshValidation.preserveSignedEntitlements(previous: original, renewed: removed))
        }
        var wildcard = original; wildcard["keychain-access-groups"] = ["TESTTEAM.*"]
        XCTAssertThrowsError(try CodeRefreshValidation.preserveSignedEntitlements(previous: original, renewed: wildcard))
        var extra = original; extra["unexpected"] = true
        XCTAssertThrowsError(try CodeRefreshValidation.preserveSignedEntitlements(previous: original, renewed: extra))
    }
    func testProfilesUseStructuralCapabilityComparisonAndRejectIdentityChanges() throws {
        let values: [String: Any] = ["application-identifier": "TESTTEAM.example.app", "keychain-access-groups": ["TESTTEAM.example.app"], "get-task-allow": true]
        func profile(_ entitlements: [String: Any], team: String = "TESTTEAM") throws -> ProvisioningProfile {
            let bytes = try PropertyListSerialization.data(fromPropertyList: ["Name": "Fixture", "UUID": UUID().uuidString, "TeamIdentifier": [team], "TeamName": "Fixture", "CreationDate": Date(), "ExpirationDate": Date().addingTimeInterval(3600), "Entitlements": entitlements], format: .xml, options: 0)
            return try ProvisioningProfile(data: bytes)
        }
        let previous = try profile(values)
        XCTAssertNoThrow(try CodeRefreshValidation.preserveIdentity(previous: previous, renewed: profile(values)))
        XCTAssertThrowsError(try CodeRefreshValidation.preserveIdentity(previous: previous, renewed: profile(values, team: "OTHER")))
        var changed = values; changed["keychain-access-groups"] = ["TESTTEAM.*"]
        XCTAssertThrowsError(try CodeRefreshValidation.preserveIdentity(previous: previous, renewed: profile(changed)))
        changed = values; changed["application-identifier"] = "OTHER.example.app"
        XCTAssertThrowsError(try CodeRefreshValidation.preserveIdentity(previous: previous, renewed: profile(changed)))
    }
}
