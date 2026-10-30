import Foundation
import SideSign
import OrbitCore

/// Blank means the public default, never an abandoned sign-in attempt.
struct CodeRefreshSignInInput {
    // SideStore's official server list: https://github.com/SideStore/anisette-servers
    static let defaultServer = URL(string: "https://new.ani.sidestore.io")!
    let appleID: String
    let password: String
    let server: URL
    let rememberPassword: Bool

    init(appleID: String, password: String, server: String, rememberPassword: Bool) throws {
        let email = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { throw CodeFailure("Enter your Apple Account email.") }
        guard !password.isEmpty else { throw CodeFailure("Enter your password.") }
        self.appleID = email
        self.password = password
        self.server = try Self.serverURL(server)
        self.rememberPassword = rememberPassword
    }

    static func serverURL(_ text: String) throws -> URL {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty { return defaultServer }
        guard !address.contains(where: { $0.isWhitespace }),
              let parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url else {
            throw CodeFailure("Enter a full HTTPS server address, or leave it blank to use SideStore.")
        }
        return url
    }
}

protocol CodeRefreshSignInService: Sendable {
    func signIn(appleID: String, password: String, anisetteURL: URL, rememberPassword: Bool,
                verify: @escaping DeveloperPortal.VerificationHandler) async throws -> [Team]
    func select(_ team: Team) async throws
}

enum CodeRefreshAccountError {
    static func message(_ error: Error) -> String {
        if case DeveloperPortalError.tooManyCertificates = error {
            return "Apple’s certificate slots are full. In Setup details, import a .p12 exported from your Mac’s Keychain. Existing certificates will stay active."
        }
        if case ServerError.underlyingError(let code, _) = error, code == -80045 {
            return "Apple rejected the sign-in helper’s identity (-80045). Clear the server in Advanced to use the current default, then try again."
        }
        if let error = error as? ServerError {
            switch error {
            case .badServerResponse, .invalidResponseFormat, .missingKey:
                return "Apple couldn’t finish sign-in. Try again in a few minutes."
            default: break
            }
        }
        return error.localizedDescription
    }
}
