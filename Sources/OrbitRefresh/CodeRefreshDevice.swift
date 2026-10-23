import Foundation
import SideSign
import IdeviceGateway
import OrbitCore

actor CodeRefreshDevice {
    private var checkedUntil = Date.distantPast
    func recentlyChecked() -> Bool { Date() < checkedUntil }
    func hasVerifiedConnection() throws -> Bool { try secrets.read("verified-connection") != nil }
    private let gateway = IdeviceGateway()
    private let secrets = CodeRefreshSecrets()
    func importPairing(_ data: Data) throws {
        checkedUntil = .distantPast
        guard data.count <= 2 * 1024 * 1024,
              let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CodeFailure("Choose this phone’s pairing file from your computer.")
        }
        let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try IdeviceGateway.validatePairingForRefresh(String(decoding: xml, as: UTF8.self))
        try secrets.write(xml, account: "pairing")
        try secrets.remove("verified-connection")
    }
    func hasPairing() throws -> Bool { try secrets.read("pairing") != nil }
    func connect() async throws -> String {
        checkedUntil = .distantPast
        guard let data = try secrets.read("pairing"), let text = String(data: data, encoding: .utf8) else {
            throw CodeFailure("Import this phone’s pairing file in Refresh settings.")
        }
        #if targetEnvironment(simulator)
        throw CodeFailure("App refresh needs a physical iPhone with LocalDevVPN connected.")
        #else
        gateway.setLogging(false)
        gateway.setDeviceEndpointIp("10.7.0.1")
        try await gateway.startForRefresh(pairingFileContent: text)
        let udid = try await gateway.fetchUDID()
        if let expected = try secrets.read("paired-udid"), String(data: expected, encoding: .utf8) != udid {
            throw CodeFailure("This pairing file connects to a different phone.")
        }
        try secrets.write(Data(udid.utf8), account: "paired-udid")
        try secrets.write(Data(udid.utf8), account: "verified-connection")
        checkedUntil = Date().addingTimeInterval(180)
        return udid
        #endif
    }
    func revision(_ bundle: String) async throws -> [String: String] { try await gateway.installedRevision(bundleID: bundle) }
    func upload(_ app: URL, bundleID: String) async throws { try await gateway.sendAppBundleAfc(bundleId: bundleID, appURL: app) }
    func install(_ app: URL, bundleID: String) async throws { try await gateway.installAppBundle(bundleId: bundleID, appName: app.lastPathComponent) }
    func profiles(root: URL) async throws -> [String: Date] {
        let scratch = root.appendingPathComponent("ProfileReadback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let path = try await gateway.dumpProfiles(docsPath: scratch.path)
        let folder = URL(fileURLWithPath: path).standardizedFileURL
        guard folder.path.hasPrefix(scratch.standardizedFileURL.path + "/") || folder == scratch.standardizedFileURL else {
            throw CodeFailure("Couldn’t read back installed profiles.")
        }
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        var result: [String: Date] = [:]
        for file in files {
            guard let bytes = try? Data(contentsOf: file), let profile = try? ProvisioningProfile(data: bytes) else { continue }
            result[profile.uuid.uuidString] = profile.expirationDate
        }
        return result
    }
}
