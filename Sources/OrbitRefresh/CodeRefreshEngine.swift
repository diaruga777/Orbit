import Foundation
import CryptoKit
import SideSign
import OrbitCore

public actor CodeRefreshEngine {
    public static let shared: CodeRefreshEngine = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbit/LocalRefresh")
        return CodeRefreshEngine(root: root)
    }()
    public let root: URL
    let account = CodeRefreshAppleAccount()
    let device = CodeRefreshDevice()
    private var busy = false
    public init(root: URL) { self.root = root }
    private func store() throws -> CodeLocalRefreshStore { try CodeLocalRefreshStore(root: root) }
    public func readiness() async throws -> [String: Bool] {
        let team = try await account.team()
        let info = Bundle.main.infoDictionary ?? [:]
        let cached = try store().apps().contains {
            $0.bundleID == Bundle.main.bundleIdentifier && $0.version == info["CFBundleShortVersionString"] as? String &&
                $0.build == info["CFBundleVersion"] as? String && $0.teamID == team?.identifier && !$0.requiresReconciliation
        }
        return ["cache": cached, "account": team != nil, "certificate": try await account.hasCertificate(), "pairing": try await device.hasPairing(), "connection": await device.recentlyChecked()]
    }
    public func setupComplete() async throws -> Bool {
        let status = try await readiness()
        let verified = try await device.hasVerifiedConnection()
        return ["cache", "account", "certificate", "pairing"].allSatisfy { status[$0] == true } && verified
    }
    /// The running bundle is installed evidence even before phone-only setup.
    /// Cached imports do not establish installation on this phone.
    public func installedSelf(deviceID: String, receipt: CodeInstalledApp?) throws -> CodeInstalledApp? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        let profiles = try? Self.products(Bundle.main.bundleURL).map {
            try ProvisioningProfile(data: Data(contentsOf: $0.appendingPathComponent("embedded.mobileprovision")))
        }
        let expiry = profiles?.map(\.expirationDate).min()
        let matching = receipt.flatMap { $0.bundleID == bundleID && $0.version == version && $0.build == build ? $0 : nil }
        guard expiry != nil || matching != nil else { return nil }
        return CodeInstalledApp(deviceID: deviceID, bundleID: bundleID, name: "Orbit", version: version, build: build,
            installedAt: matching?.installedAt ?? .distantPast, profileExpiresAt: expiry ?? matching?.profileExpiresAt)
    }
    public func verifyConnection() async throws {
        guard !busy else { throw CodeFailure("Wait for the current refresh to finish.") }
        _ = try await device.connect()
    }
    public func apps() throws -> [CodeLocalRefreshApp] {
        let store = try store()
        if !busy {
            for var app in store.apps() where app.state == .signing {
                app.state = .failed; app.failure = "Refresh was interrupted. Try again."; try store.save(app)
            }
        }
        return store.apps()
    }
    public func setAutomatic(id: String, enabled: Bool) throws {
        guard !busy else { throw CodeFailure("Wait for the current refresh to finish.") }
        guard var app = try apps().first(where: { $0.id == id }) else { return }
        app.automatic = enabled; try store().save(app)
    }
    public func cacheSelf() throws { _ = try cache(appURL: Bundle.main.bundleURL) }
    public func importIPA(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let scratch = root.appendingPathComponent("Import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2 * 1024 * 1024 * 1024 else { throw CodeFailure("This build is too large to cache on the phone.") }
        let app = try CodeRefreshIPA.extract(url, to: scratch)
        _ = try cache(appURL: app)
    }
    public func cacheFromMac(fetch: @Sendable (Int) async throws -> CodeRefreshArchiveChunk) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ipa = root.appendingPathComponent("Download-" + UUID().uuidString + ".ipa")
        FileManager.default.createFile(atPath: ipa.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: ipa) }
        let file = try FileHandle(forWritingTo: ipa); defer { try? file.close() }
        var expected: CodeRefreshArchiveChunk?, offset = 0, hash = SHA256()
        repeat {
            try Task.checkCancellation()
            let chunk = try await fetch(offset)
            guard UUID(uuidString: chunk.artifactID) != nil, chunk.byteCount > 0, chunk.byteCount <= 2 * 1024 * 1024 * 1024,
                  chunk.offset == offset, !chunk.bytes.isEmpty, chunk.bytes.count <= 256 * 1024,
                  chunk.bytes.count <= chunk.byteCount - offset else { throw CodeFailure("The build download was incomplete. Try again.") }
            if let expected { guard expected.artifactID == chunk.artifactID, expected.digest == chunk.digest, expected.byteCount == chunk.byteCount else { throw CodeFailure("The build changed during download. Try again.") } }
            else { expected = chunk }
            try file.write(contentsOf: chunk.bytes); hash.update(data: chunk.bytes); offset += chunk.bytes.count
        } while offset < (expected?.byteCount ?? 0)
        try file.synchronize()
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected?.digest else { throw CodeFailure("The downloaded build failed its integrity check. Try again.") }
        try importIPA(ipa)
    }
    @discardableResult private func cache(appURL: URL) throws -> CodeLocalRefreshApp {
        guard !busy else { throw CodeFailure("Wait for the current refresh to finish.") }
        let products = try Self.products(appURL)
        let main = try Self.info(appURL)
        guard let bundle = main["CFBundleIdentifier"] as? String, !bundle.lowercased().contains("webdriveragent"),
              let version = main["CFBundleShortVersionString"] as? String, let build = main["CFBundleVersion"] as? String else {
            throw CodeFailure("Choose a development build with a bundle identifier and version.")
        }
        let profiles = try products.map { try ProvisioningProfile(data: Data(contentsOf: $0.appendingPathComponent("embedded.mobileprovision"))) }
        guard let profile = profiles.first, profiles.allSatisfy({ $0.teamIdentifier == profile.teamIdentifier && $0.entitlements["get-task-allow"] as? Bool == true }),
              let expiry = profiles.map(\.expirationDate).min() else { throw CodeFailure("Cache an iOS development build to refresh it here.") }
        let store = try store()
        let old = store.apps().first { $0.bundleID == bundle }
        guard old?.requiresReconciliation != true else { throw CodeFailure("Check the pending installation before replacing this cached build.") }
        var app = CodeLocalRefreshApp(id: old?.id ?? UUID().uuidString, name: main["CFBundleDisplayName"] as? String ?? main["CFBundleName"] as? String ?? bundle,
            bundleID: bundle, teamID: profile.teamIdentifier, version: version, build: build, expiresAt: expiry)
        app.automatic = old?.automatic ?? false
        let directory = try store.directory(app.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let incoming = directory.appendingPathComponent("Incoming.app"), cached = directory.appendingPathComponent("Cached.app")
        try? FileManager.default.removeItem(at: incoming)
        try FileManager.default.copyItem(at: appURL, to: incoming)
        _ = try Self.digest(incoming)
        // Keep the previous source until its replacement has copied completely.
        if FileManager.default.fileExists(atPath: cached.path) { _ = try FileManager.default.replaceItemAt(cached, withItemAt: incoming) }
        else { try FileManager.default.moveItem(at: incoming, to: cached) }
        try Self.digest(cached).write(to: directory.appendingPathComponent("digest"), atomically: true, encoding: .utf8)
        try store.save(app)
        return app
    }
    public func refreshDue() async -> Bool {
        var success = true
        do {
            for app in try apps() where app.requiresReconciliation {
                do { try Task.checkCancellation(); try await reconcile(id: app.id) } catch { success = false }
            }
            let due = try apps().filter { $0.isDue(at: Date()) }.sorted { $0.bundleID != Bundle.main.bundleIdentifier && $1.bundleID == Bundle.main.bundleIdentifier }
            for app in due {
                if Task.isCancelled { return false }
                do { try await refresh(id: app.id) } catch { success = false }
            }
        } catch { return false }
        return success
    }
    public func refresh(id: String) async throws {
        guard !busy else { throw CodeFailure("Another refresh is in progress.") }
        busy = true; defer { busy = false }
        let store = try store()
        guard var app = store.apps().first(where: { $0.id == id }) else { throw CodeFailure("Cache this app’s build first.") }
        if app.requiresReconciliation { try await reconcile(id: id); return }
        let directory = try store.directory(id), cached = directory.appendingPathComponent("Cached.app"), work = directory.appendingPathComponent("Signed.app")
        app.lastAttempt = Date(); app.state = .signing; app.failure = nil; try store.save(app)
        do {
            let expected = try String(contentsOf: directory.appendingPathComponent("digest"), encoding: .utf8)
            guard try Self.digest(cached) == expected else { throw CodeFailure("The cached build changed. Cache it again before refreshing.") }
            let udid = try await device.connect()
            let installed = try await device.revision(app.bundleID)
            guard installed["CFBundleIdentifier"] == app.bundleID, installed["CFBundleShortVersionString"] == app.version, installed["CFBundleVersion"] == app.build else {
                throw CodeFailure("The installed app changed. Cache its current build before refreshing.")
            }
            try? FileManager.default.removeItem(at: work); try FileManager.default.copyItem(at: cached, to: work)
            let products = try Self.products(work)
            let bundles = try products.map { try Self.bundleID($0) }
            let (team, key, profiles) = try await account.signingMaterial(bundleIDs: bundles, teamID: app.teamID, deviceID: udid, deviceName: ProcessInfo.processInfo.hostName)
            for (product, profile) in zip(products, profiles) {
                let previous = try ProvisioningProfile(data: Data(contentsOf: product.appendingPathComponent("embedded.mobileprovision")))
                try Self.preserveIdentity(previous: previous, renewed: profile)
            }
            try Task.checkCancellation()
            try await AppBundleSigner(team: team, keyStore: key).signApp(at: work, provisioningProfiles: profiles)
            guard try Self.bundleID(work) == app.bundleID else { throw CodeFailure("Signing changed this app’s identifier.") }
            try await device.upload(work, bundleID: app.bundleID)
            try Task.checkCancellation()
            #if os(iOS)
            if app.bundleID == Bundle.main.bundleIdentifier { try await CodeRefreshLifecycle.waitForBackground() }
            #endif
            app.pendingProfiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.uuid.uuidString, $0.expirationDate) })
            app.state = .installing; try store.save(app) // Durable before the self-update can terminate us.
            try await device.install(work, bundleID: app.bundleID)
            try await reconcile(id: id)
        } catch {
            if app.state == .installing { app.state = .unknown; app.failure = "Check the installation with LocalDevVPN connected." }
            else { app.state = .failed; app.failure = error.localizedDescription }
            try store.save(app); throw error
        }
    }
    public func clearPending(id: String) throws {
        guard !busy else { throw CodeFailure("Wait for the current refresh to finish.") }
        let store = try store()
        guard var app = store.apps().first(where: { $0.id == id }), app.requiresReconciliation,
              let attempt = app.lastAttempt, Date().timeIntervalSince(attempt) >= 15 * 60 else {
            throw CodeFailure("Wait 15 minutes after the last attempt, then check the installation before clearing it.")
        }
        app.state = .failed; app.pendingProfiles = [:]; app.failure = "Refresh stopped. The cached build is ready to retry."
        try store.save(app)
    }
    public func reconcile(id: String) async throws {
        let store = try store()
        guard var app = store.apps().first(where: { $0.id == id }), app.requiresReconciliation else { return }
        _ = try await device.connect()
        let revision = try await device.revision(app.bundleID)
        let profiles = try await device.profiles(root: root)
        try app.confirm(version: revision["CFBundleShortVersionString"] ?? "", build: revision["CFBundleVersion"] ?? "", installedProfiles: profiles, at: Date())
        try store.save(app)
    }
    private static func products(_ app: URL) throws -> [URL] {
        if FileManager.default.fileExists(atPath: app.appendingPathComponent("Watch").path) {
            throw CodeFailure("Builds with a Watch app need to be refreshed from the Mac.")
        }
        let extensions = ((try? FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "appex" }.sorted { $0.path < $1.path }
        return [app] + extensions
    }
    private static func info(_ app: URL) throws -> [String: Any] {
        guard let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] else { throw CodeFailure("Couldn’t read this build.") }
        return result
    }
    private static func bundleID(_ app: URL) throws -> String {
        guard let id = try info(app)["CFBundleIdentifier"] as? String else { throw CodeFailure("This build has no app identifier.") }; return id
    }
    private static func preserveIdentity(previous: ProvisioningProfile, renewed: ProvisioningProfile) throws {
        guard previous.bundleIdentifier == renewed.bundleIdentifier, previous.teamIdentifier == renewed.teamIdentifier else { throw CodeFailure("The refreshed profile changed this app’s identity.") }
        for key in ["keychain-access-groups", "com.apple.security.application-groups", "com.apple.developer.icloud-container-identifiers", "com.apple.developer.ubiquity-kvstore-identifier", "com.apple.developer.associated-domains"] {
            guard let old = previous.entitlements[key] else { continue }
            guard let new = renewed.entitlements[key], String(describing: old) == String(describing: new) else {
                throw CodeFailure("The refreshed profile doesn’t preserve this app’s capabilities. Check signing on the Mac before refreshing.")
            }
        }
    }
    private static func digest(_ app: URL) throws -> String {
        let canonical = app.resolvingSymlinksInPath()
        let base = canonical.path + "/"
        let files = FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])?.compactMap { $0 as? URL }.sorted { $0.path < $1.path } ?? []
        guard !files.isEmpty else { throw CodeFailure("The cached build is empty.") }
        var digest = SHA256()
        for file in files {
            guard file.resolvingSymlinksInPath().path.hasPrefix(base) else { throw CodeFailure("This build contains a file outside its app bundle.") }
            digest.update(data: Data(file.path.dropFirst(base.count).utf8)); digest.update(data: Data([0]))
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
