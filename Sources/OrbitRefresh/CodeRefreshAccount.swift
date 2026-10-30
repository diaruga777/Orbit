import Foundation
import SideSign
import OrbitCore

struct CodeRefreshAccount: Codable {
    var auth: AuthSession
    var team: Team?
    var anisetteURL: URL
    var identifier: UUID
    var adiBlob: Data?
}

actor CodeRefreshAppleAccount: CodeRefreshSignInService {
    private struct Login: Codable { var appleID: String; var password: String }
    private let secrets = CodeRefreshSecrets()
    private let portal = DeveloperPortal()
    private var account: CodeRefreshAccount? {
        get throws {
            guard let bytes = try secrets.read("apple-session") else { return nil }
            return try JSONDecoder().decode(CodeRefreshAccount.self, from: bytes)
        }
    }
    func team() throws -> Team? { try account?.team }
    func signInServer() throws -> URL { try account?.anisetteURL ?? CodeRefreshSignInInput.defaultServer }
    func hasCertificate() throws -> Bool { try secrets.read("signing-p12").map { !$0.isEmpty } ?? false }
    func signIn(appleID: String, password: String, anisetteURL: URL, rememberPassword: Bool = false,
                verify: @escaping DeveloperPortal.VerificationHandler) async throws -> [Team] {
        let input = try CodeRefreshSignInInput(appleID: appleID, password: password, server: anisetteURL.absoluteString, rememberPassword: rememberPassword)
        let previous = try account
        let identifier = previous?.identifier ?? UUID()
        let manager = AnisetteDataManager(mode: .remote(server: anisetteURL))
        let anisette: (data: AnisetteData, newAdiBlob: Data?)
        do {
            anisette = try await manager.fetchAnisetteData(identifier: identifier,
                existingAdiBlob: previous?.anisetteURL == anisetteURL ? previous?.adiBlob : nil)
        } catch {
            try Task.checkCancellation()
            throw CodeFailure("Couldn’t reach the sign-in helper. Try again, or change the server in Advanced.")
        }
        try Task.checkCancellation()
        let auth = try await portal.authenticate(appleID: input.appleID, password: password, anisetteData: anisette.data,
            xcodeVersion: "26.2", accountRepairHandler: { _, _ in .cancel }, verificationHandler: verify)
        try Task.checkCancellation()
        let teams = try await portal.fetchTeams(for: auth.account, session: auth.session)
        try Task.checkCancellation()
        guard !teams.isEmpty else { throw CodeFailure("No signing teams were found. Finish setting up this account in Xcode, then try again.") }
        let state = CodeRefreshAccount(auth: auth, team: previous?.auth.account.identifier == auth.account.identifier ? previous?.team : nil, anisetteURL: anisetteURL, identifier: identifier, adiBlob: anisette.newAdiBlob)
        try save(state)
        if previous?.auth.account.identifier != auth.account.identifier { try secrets.remove("signing-p12") }
        if rememberPassword { try secrets.write(JSONEncoder().encode(Login(appleID: input.appleID, password: password)), account: "apple-login") }
        else { try secrets.remove("apple-login") }
        return teams
    }
    private func save(_ value: CodeRefreshAccount) throws { try secrets.write(JSONEncoder().encode(value), account: "apple-session") }
    func select(_ team: Team) throws {
        guard var value = try account else { throw CodeFailure("Sign in with your Apple account first.") }
        value.team = team; try save(value)
    }
    private func session() async throws -> (Team, Session) {
        guard var value = try account, let team = value.team else {
            throw CodeFailure("Sign in with your Apple account to refresh apps.")
        }
        let manager = AnisetteDataManager(mode: .remote(server: value.anisetteURL))
        let anisette = try await manager.fetchAnisetteData(identifier: value.identifier, existingAdiBlob: value.adiBlob)
        var session = value.auth.session
        if !session.isValid {
            guard let bytes = try secrets.read("apple-login") else { throw CodeFailure("Sign in again to renew your Apple session.") }
            let login = try JSONDecoder().decode(Login.self, from: bytes)
            let renewed = try await portal.authenticate(appleID: login.appleID, password: login.password, anisetteData: anisette.data,
                xcodeVersion: "26.2", accountRepairHandler: { _, _ in .cancel }, verificationHandler: { _ in .cancel })
            guard renewed.account.identifier == value.auth.account.identifier else { throw CodeFailure("The Apple account changed. Sign in again.") }
            session = renewed.session
        }
        session.anisetteData = anisette.data
        value.adiBlob = anisette.newAdiBlob ?? value.adiBlob
        value.auth = AuthSession(account: value.auth.account, session: session); try save(value)
        return (team, session)
    }
    func createCertificate() async throws {
        let (team, session) = try await session()
        let key = try await portal.addCertificate(machineName: "Orbit", type: .development, to: team, session: session)
        try secrets.write(key.exportP12(), account: "signing-p12")
    }
    func importCertificate(_ data: Data, password: String) throws {
        let key = try KeyStore(p12Data: data, password: password)
        try secrets.write(key.exportP12(), account: "signing-p12")
    }
    func signingMaterial(bundleIDs: [String], teamID: String, deviceID: String, deviceName: String) async throws -> (Team, KeyStore, [ProvisioningProfile]) {
        let (team, session) = try await session()
        guard team.identifier == teamID else { throw CodeFailure("Choose the Apple team that signed this build. Refresh keeps its existing app identity.") }
        guard let data = try secrets.read("signing-p12"), !data.isEmpty else { throw CodeFailure("Import your signing certificate or create one in Refresh settings.") }
        let key = try KeyStore(p12Data: data)
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
        for account in ["apple-session", "apple-login", "signing-p12"] { try secrets.remove(account) }
    }
}
