import XCTest
import SideSign
@testable import OrbitRefresh

final class CodeRefreshAccountTests: XCTestCase {
    private let team = Team(identifier: "TESTTEAM", name: "Example", type: .free)
    private let metadata = Data(#"{"client_info":"<Mac ADI test>","user_agent":"test-akd/1"}"#.utf8)
    private var data: AnisetteData {
        AnisetteData(machineID: "machine", oneTimePassword: "otp", localUserID: "local", routingInfo: "1",
            deviceID: "device", serialNumber: "serial", clientInfo: "<Mac ADI test>", userAgent: "test-akd/1", clientTime: "time", locale: "en_AU", timeZone: "AEDT")
    }
    private func auth(_ identifier: String = "ACCOUNT") -> AuthSession {
        AuthSession(account: Account(appleID: "person@example.test", identifier: identifier),
            session: Session(dsid: "dsid", authToken: "token", anisetteData: data, xcodeVersion: "26.2"))
    }
    private func network(_ identifier: String = "ACCOUNT", blob: Data? = Data([1, 2])) -> CodeRefreshAccountNetwork {
        let metadata = metadata, auth = auth(identifier), team = team
        var network = CodeRefreshAccountNetwork()
        network.anisette.load = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.path, "/v3/client_info")
            return (metadata, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        network.anisette.fetch = { _, _, _, headers in
            XCTAssertEqual(headers.clientInfo, "<Mac ADI test>")
            XCTAssertEqual(headers.userAgent, "test-akd/1")
            return (auth.session.anisetteData, blob)
        }
        network.authenticate = { email, password, data, _ in
            XCTAssertEqual(email, "person@example.test"); XCTAssertEqual(password, " password ")
            XCTAssertEqual(data.clientInfo, "<Mac ADI test>")
            return auth
        }
        network.teams = { _ in [team] }
        return network
    }
    private func signIn(_ account: CodeRefreshAppleAccount, remember: Bool = true) async throws {
        _ = try await account.signIn(appleID: " person@example.test ", password: " password ",
            anisetteURL: CodeRefreshSignInInput.defaultServer, rememberPassword: remember, verify: { _ in .cancel })
    }
    private func saved(_ store: MemorySecrets) throws -> CodeRefreshCredentials {
        try JSONDecoder().decode(CodeRefreshCredentials.self, from: XCTUnwrap(store.read("apple-credentials")))
    }
    func testSignInTeamAndRememberAreSavedTogetherAndReusedBlobSurvives() async throws {
        let store = MemorySecrets()
        let first = CodeRefreshAppleAccount(secrets: store, network: network())
        try await signIn(first); try await first.select(team)
        let previous = try XCTUnwrap(saved(store).account)
        var next = network(blob: nil)
        next.anisette.fetch = { _, identifier, existing, _ in
            XCTAssertEqual(identifier, previous.identifier)
            XCTAssertEqual(existing, Data([1, 2]))
            return (previous.auth.session.anisetteData, nil)
        }
        let resumed = CodeRefreshAppleAccount(secrets: store, network: next)
        try await signIn(resumed, remember: false)
        let state = try saved(store)
        XCTAssertEqual(state.account?.team, team)
        XCTAssertEqual(state.account?.adiBlob, Data([1, 2]))
        XCTAssertNil(state.login)
    }
    func testHelperOrIdentityChangeCannotReuseProvisioningBlob() async throws {
        let old = CodeRefreshAccount(auth: auth(), team: team, anisetteURL: URL(string: "https://old.example.test")!, identifier: UUID(), adiBlob: Data([9]))
        var helper = network().anisette
        let data = data
        helper.fetch = { _, _, blob, _ in XCTAssertNil(blob); return (data, Data([3])) }
        let result = try await helper.data(server: CodeRefreshSignInInput.defaultServer, identifier: old.identifier, previous: old)
        XCTAssertEqual(result.blob, Data([3]))
        var changed = old; changed.anisetteURL = CodeRefreshSignInInput.defaultServer
        var session = changed.auth.session; session.anisetteData.clientInfo = "old identity"
        changed.auth = AuthSession(account: changed.auth.account, session: session)
        _ = try await helper.data(server: changed.anisetteURL, identifier: changed.identifier, previous: changed)
    }
    func testRejectedCachedBlobReprovisionsOnceOnSameHelper() async throws {
        let old = CodeRefreshAccount(auth: auth(), team: team, anisetteURL: CodeRefreshSignInInput.defaultServer, identifier: UUID(), adiBlob: Data([9]))
        let calls = Calls(), data = data
        var helper = network().anisette
        helper.fetch = { server, identifier, blob, _ in
            XCTAssertEqual(server, old.anisetteURL); XCTAssertEqual(identifier, old.identifier)
            await calls.hit()
            if blob != nil { throw AnisetteError.badServerResponse(statusCode: -1, payload: "GetHeadersError") }
            return (data, Data([4]))
        }
        let result = try await helper.data(server: old.anisetteURL, identifier: old.identifier, previous: old)
        XCTAssertEqual(result.blob, Data([4]))
        let count = await calls.count; XCTAssertEqual(count, 2)
    }
    func testMetadataFailureNeverAuthenticatesOrOverwritesCredentials() async throws {
        for status in [302, 503] {
            let store = MemorySecrets(), calls = Calls()
            var net = network()
            net.anisette.load = { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
            net.authenticate = { _, _, _, _ in await calls.hit(); throw CancellationError() }
            let account = CodeRefreshAppleAccount(secrets: store, network: net)
            do { try await signIn(account); XCTFail("Expected helper failure") } catch { }
            let count = await calls.count; XCTAssertEqual(count, 0)
            XCTAssertNil(try store.read("apple-credentials"))
        }
    }
    func testEmptyTeamsAndFailedAppleAuthenticationPreservePreviousState() async throws {
        let store = MemorySecrets()
        let first = CodeRefreshAppleAccount(secrets: store, network: network())
        try await signIn(first); try await first.select(team)
        let original = try store.read("apple-credentials")
        var net = network("OTHER"); net.teams = { _ in [] }
        do { try await signIn(CodeRefreshAppleAccount(secrets: store, network: net)); XCTFail("Expected empty teams") } catch { }
        XCTAssertEqual(try store.read("apple-credentials"), original)
        net = network("OTHER"); net.authenticate = { _, _, _, _ in throw ServerError.underlyingError(code: -80045, message: "Apple rejected") }
        do { try await signIn(CodeRefreshAppleAccount(secrets: store, network: net)); XCTFail("Expected Apple failure") } catch {
            XCTAssertTrue(CodeRefreshAccountError.message(error).contains("Advanced"))
        }
        XCTAssertEqual(try store.read("apple-credentials"), original)
    }
    func testLegacyMigrationAndSignOutPreservePairingAndClearAccountMaterial() async throws {
        let store = MemorySecrets()
        let old = CodeRefreshAccount(auth: auth(), team: team, anisetteURL: CodeRefreshSignInInput.defaultServer, identifier: UUID(), adiBlob: Data([1]))
        try store.write(JSONEncoder().encode(old), account: "apple-session")
        try store.write(JSONEncoder().encode(CodeRefreshLogin(appleID: "person@example.test", password: " password ")), account: "apple-login")
        try store.write(Data([7]), account: "signing-p12")
        try store.write(Data([8]), account: "pairing")
        let account = CodeRefreshAppleAccount(secrets: store, network: network())
        try await account.select(team)
        XCTAssertEqual(try saved(store).certificate, Data([7]))
        XCTAssertNil(try store.read("apple-session"))
        try await account.signOut()
        let selected = try await account.team(), cert = try await account.hasCertificate()
        XCTAssertNil(selected); XCTAssertFalse(cert)
        XCTAssertNil(try saved(store).login)
        XCTAssertEqual(try store.read("pairing"), Data([8]))
    }
    func testTeamSwitchDropsOldCertificateAndFailedWriteIsAtomic() async throws {
        let store = MemorySecrets()
        var state = CodeRefreshCredentials(account: CodeRefreshAccount(auth: auth(), team: team, anisetteURL: CodeRefreshSignInInput.defaultServer, identifier: UUID()), certificate: Data([9]))
        try store.write(JSONEncoder().encode(state), account: "apple-credentials")
        let account = CodeRefreshAppleAccount(secrets: store, network: network())
        let other = Team(identifier: "OTHER", name: "Other", type: .organization)
        store.failWrites = true
        do { try await account.select(other); XCTFail("Expected write failure") } catch { }
        XCTAssertEqual(try saved(store).account?.team, team)
        XCTAssertEqual(try saved(store).certificate, Data([9]))
        store.failWrites = false
        try await account.select(other)
        state = try saved(store)
        XCTAssertEqual(state.account?.team, other); XCTAssertNil(state.certificate)
    }
    func testAccountSwitchAndRemovedTeamDropCertificate() async throws {
        for changeAccount in [false, true] {
            let store = MemorySecrets()
            let state = CodeRefreshCredentials(account: CodeRefreshAccount(auth: auth(), team: team, anisetteURL: CodeRefreshSignInInput.defaultServer, identifier: UUID()), certificate: Data([9]))
            try store.write(JSONEncoder().encode(state), account: "apple-credentials")
            var net = network(changeAccount ? "OTHER" : "ACCOUNT")
            if !changeAccount { net.teams = { _ in [Team(identifier: "SECOND", name: "Second", type: .free)] } }
            try await signIn(CodeRefreshAppleAccount(secrets: store, network: net))
            XCTAssertNil(try saved(store).certificate); XCTAssertNil(try saved(store).account?.team)
        }
    }
    func testCancellationAndOverlappingAccountChangesCannotPersist() async throws {
        let store = MemorySecrets(), gate = Gate()
        var net = network()
        let auth = auth()
        net.authenticate = { _, _, _, _ in await gate.pause(); return auth }
        let account = CodeRefreshAppleAccount(secrets: store, network: net)
        let task = Task { try await self.signIn(account) }
        while !(await gate.waiting) { await Task.yield() }
        do { try await account.signOut(); XCTFail("Expected busy") } catch { }
        do { try await account.select(team); XCTFail("Expected busy") } catch { }
        task.cancel(); await gate.resume()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertNil(try store.read("apple-credentials"))
        try await account.signOut() // Lock was released after cancellation.
    }
    func testInvalidMetadataAndRawServerPayloadsAreRejected() throws {
        for value in [#"{"client_info":"","user_agent":"x"}"#, #"{"client_info":"x\r\ninjected: y","user_agent":"x"}"#, #"{"client_info":"x"}"#] {
            XCTAssertThrowsError(try CodeRefreshAnisetteIdentity(data: Data(value.utf8)))
        }
        XCTAssertThrowsError(try CodeRefreshAnisetteIdentity(data: Data(repeating: 32, count: 8193)))
        XCTAssertFalse(CodeRefreshAccountError.message(ServerError.missingKey(key: "token", jsonPayload: "SECRET")).contains("SECRET"))
        XCTAssertEqual(CodeRefreshAnisette.portal(for: data).customHeaders.grandSlam.userAgent, data.userAgent)
    }
}

private final class MemorySecrets: CodeRefreshSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failWrites = false
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        values[account] = data
    }
    func remove(_ account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = nil }
}
private actor Calls { var count = 0; func hit() { count += 1 } }
private actor Gate {
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
