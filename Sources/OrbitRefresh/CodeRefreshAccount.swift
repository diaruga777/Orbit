import Foundation
import SideSign
import OrbitCore

struct CodeRefreshAccount: Codable, Sendable {
    var auth: AuthSession
    var team: Team?
    var anisetteURL: URL
    var identifier: UUID
    var adiBlob: Data?
}

struct CodeRefreshLogin: Codable, Sendable { var appleID: String; var password: String }
/// One atomic Keychain update keeps the session, remembered login and key together.
struct CodeRefreshCredentials: Codable, Sendable {
    var account: CodeRefreshAccount?
    var login: CodeRefreshLogin?
    var certificate: Data?
}

struct CodeRefreshAccountNetwork: Sendable {
    var anisette = CodeRefreshAnisette()
    var authenticate: @Sendable (String, String, AnisetteData, @escaping DeveloperPortal.VerificationHandler) async throws -> AuthSession = { email, password, data, verify in
        try await CodeRefreshAnisette.portal(for: data).authenticate(appleID: email, password: password, anisetteData: data,
            xcodeVersion: "26.2", accountRepairHandler: { _, _ in .cancel }, verificationHandler: verify)
    }
    var teams: @Sendable (AuthSession) async throws -> [Team] = { auth in
        try await CodeRefreshAnisette.portal(for: auth.session.anisetteData).fetchTeams(for: auth.account, session: auth.session)
    }
}

actor CodeRefreshAppleAccount: CodeRefreshSignInService {
    private let secrets: any CodeRefreshSecretStore
    private let network: CodeRefreshAccountNetwork
    private var working = false
    init(secrets: any CodeRefreshSecretStore = CodeRefreshSecrets(), network: CodeRefreshAccountNetwork = .init()) {
        self.secrets = secrets; self.network = network
    }
    private func begin() throws {
        guard !working else { throw CodeFailure("Wait for the current Apple account action to finish.") }
        working = true
    }
    private func credentials() throws -> CodeRefreshCredentials {
        if let bytes = try secrets.read("apple-credentials") { return try JSONDecoder().decode(CodeRefreshCredentials.self, from: bytes) }
        // Read legacy items without destroying them. Migrate only after a successful save.
        let account = try secrets.read("apple-session").map { try JSONDecoder().decode(CodeRefreshAccount.self, from: $0) }
        let login = try secrets.read("apple-login").map { try JSONDecoder().decode(CodeRefreshLogin.self, from: $0) }
        return CodeRefreshCredentials(account: account, login: login, certificate: try secrets.read("signing-p12"))
    }
    private func save(_ value: CodeRefreshCredentials) throws {
        try secrets.write(JSONEncoder().encode(value), account: "apple-credentials")
        for key in ["apple-session", "apple-login", "signing-p12"] { try? secrets.remove(key) }
    }
    func team() throws -> Team? { try credentials().account?.team }
    func signInServer() throws -> URL { try credentials().account?.anisetteURL ?? CodeRefreshSignInInput.defaultServer }
    func hasCertificate() throws -> Bool {
        let state = try credentials()
        guard let data = state.certificate, let team = state.account?.team,
              let key = try? KeyStore(p12Data: data) else { return false }
        return (try? CodeRefreshValidation.certificate(key.certificate, teamID: team.identifier)) != nil
    }
    func signIn(appleID: String, password: String, anisetteURL: URL, rememberPassword: Bool = false,
                verify: @escaping DeveloperPortal.VerificationHandler) async throws -> [Team] {
        let input = try CodeRefreshSignInInput(appleID: appleID, password: password, server: anisetteURL.absoluteString, rememberPassword: rememberPassword)
        try begin(); defer { working = false }
        var state = try credentials()
        let previous = state.account
        let identifier = previous?.identifier ?? UUID()
        let anisette = try await network.anisette.data(server: input.server, identifier: identifier, previous: previous)
        try Task.checkCancellation()
        let auth = try await network.authenticate(input.appleID, input.password, anisette.data, verify)
        try Task.checkCancellation()
        let teams = try await network.teams(auth)
        try Task.checkCancellation()
        guard !teams.isEmpty else { throw CodeFailure("No signing teams were found. Finish setting up this account in Xcode, then try again.") }
        let sameAccount = previous?.auth.account.identifier == auth.account.identifier
        let team = sameAccount ? teams.first(where: { $0.identifier == previous?.team?.identifier }) : nil
        state.account = CodeRefreshAccount(auth: auth, team: team, anisetteURL: input.server, identifier: identifier, adiBlob: anisette.blob)
        if !sameAccount || (previous?.team != nil && team == nil) { state.certificate = nil }
        state.login = rememberPassword ? CodeRefreshLogin(appleID: input.appleID, password: input.password) : nil
        try save(state)
        return teams
    }
    func select(_ team: Team) throws {
        try begin(); defer { working = false }
        var state = try credentials()
        guard var value = state.account else { throw CodeFailure("Sign in with your Apple account first.") }
        if let previous = value.team, previous.identifier != team.identifier { state.certificate = nil }
        value.team = team; state.account = value; try save(state)
    }
    private func session() async throws -> (Team, Session) {
        var state = try credentials()
        guard var value = state.account, let team = value.team else {
            throw CodeFailure("Sign in with your Apple account to refresh apps.")
        }
        let anisette = try await network.anisette.data(server: value.anisetteURL, identifier: value.identifier, previous: value)
        try Task.checkCancellation()
        var session = value.auth.session
        if !session.isValid {
            guard let login = state.login else { throw CodeFailure("Sign in again to renew your Apple session.") }
            let renewed = try await network.authenticate(login.appleID, login.password, anisette.data, { _ in .cancel })
            guard renewed.account.identifier == value.auth.account.identifier else { throw CodeFailure("The Apple account changed. Sign in again.") }
            session = renewed.session
        }
        try Task.checkCancellation()
        session.anisetteData = anisette.data
        value.adiBlob = anisette.blob
        value.auth = AuthSession(account: value.auth.account, session: session)
        state.account = value; try save(state)
        return (team, session)
    }
    func createCertificate() async throws {
        try begin(); defer { working = false }
        // Do not consume another slot after a double tap or a lost UI response.
        guard try !hasCertificate() else { return }
        let (team, session) = try await session()
        let key = try await CodeRefreshAnisette.portal(for: session.anisetteData).addCertificate(machineName: "Orbit", type: .development, to: team, session: session)
        try CodeRefreshValidation.certificate(key.certificate, teamID: team.identifier)
        var state = try credentials(); state.certificate = try key.exportP12(); try save(state)
    }
    func importCertificate(_ data: Data, password: String) throws {
        try begin(); defer { working = false }
        var state = try credentials()
        guard state.account?.team != nil else { throw CodeFailure("Sign in and choose your Apple team first.") }
        let key = try KeyStore(p12Data: data, password: password)
        try CodeRefreshValidation.certificate(key.certificate, teamID: state.account!.team!.identifier)
        state.certificate = try key.exportP12(); try save(state)
    }
    func signingMaterial(bundleIDs: [String], teamID: String, deviceID: String, deviceName: String) async throws -> (Team, KeyStore, [ProvisioningProfile]) {
        try begin(); defer { working = false }
        let (team, session) = try await session()
        let portal = CodeRefreshAnisette.portal(for: session.anisetteData)
        guard team.identifier == teamID else { throw CodeFailure("Choose the Apple team that signed this build. Refresh keeps its existing app identity.") }
        guard let data = try credentials().certificate, !data.isEmpty else { throw CodeFailure("Import your signing certificate or create one in Refresh settings.") }
        let key = try KeyStore(p12Data: data)
        try CodeRefreshValidation.certificate(key.certificate, teamID: teamID)
        let certificates = try await portal.fetchCertificates(for: team, session: session)
        guard let certificate = certificates.first(where: { $0.serialNumberHex == key.certificate.serialNumberHex }), let certificateID = certificate.identifier else {
            throw CodeFailure("This signing certificate is no longer active. Import an active certificate or create one in Refresh settings.")
        }
        var devices = try await portal.fetchDevices(for: team, types: [.iPhone, .iPad], session: session)
        if !devices.contains(where: { $0.identifier == deviceID }) {
            devices.append(try await portal.registerDevice(name: deviceName, identifier: deviceID, type: .iPhone, team: team, session: session))
        }
        guard let device = devices.first(where: { $0.identifier == deviceID }), let portalDevice = device.deviceID else { throw CodeFailure("Apple couldn’t register this phone.") }
        let appIDs = try await portal.fetchAppIDs(for: team, session: session)
        let listed = try await portal.listProvisioningProfiles(for: team, session: session)
        var profiles: [ProvisioningProfile] = []
        for bundleID in bundleIDs {
            guard let appID = appIDs.first(where: { $0.bundleIdentifier == bundleID }) else { throw CodeFailure("This build’s app identifier isn’t registered with the selected team. Set up signing on your Mac once, then cache the build again.") }
            let name = "Orbit " + bundleID
            let profile: ProvisioningProfile
            if let existing = listed.first(where: { $0.name == name && $0.bundleIdentifier == bundleID }), let profileID = existing.identifier {
                profile = try await portal.updateProvisioningProfile(profileID: profileID, name: name, appIDId: appID.identifier,
                    certificateIDs: [certificateID], deviceIDs: [portalDevice], subPlatform: nil, distributionType: "limited", team: team, session: session)
            } else {
                profile = try await portal.createProvisioningProfile(name: name, appID: appID, certificateIDs: [certificateID], deviceIDs: [portalDevice], team: team, session: session)
            }
            guard profile.bundleIdentifier == bundleID, profile.teamIdentifier == teamID, profile.deviceIDs.contains(deviceID),
                  profile.expirationDate > Date().addingTimeInterval(48 * 3600), profile.certificates.contains(where: { $0.serialNumberHex == key.certificate.serialNumberHex }) else {
                throw CodeFailure("Apple didn’t return a fresh profile for this build and phone.")
            }
            profiles.append(profile)
        }
        return (team, key, profiles)
    }
    func signOut() throws {
        try begin(); defer { working = false }
        // Persist the signed-out state first, so a partial legacy cleanup cannot restore it.
        try save(CodeRefreshCredentials())
        for key in ["apple-session", "apple-login", "signing-p12"] { try secrets.remove(key) }
    }
}
