import Foundation
import OrbitCore

/// Local setup action only. No RPC exposes this method or the resulting keys.
public enum OrbitPairingExport {
    public static let missingHelperMessage = "This copy of Orbit Mac is missing its pairing helper. Update or reinstall Orbit Mac, then try again. There’s nothing to set up on your iPhone first."

    public static func helper(in bundleURL: URL) throws -> URL {
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/orbit-apple-adapter")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw CodeFailure(missingHelperMessage) }
        return helper
    }

    public static func export(deviceID: String, root: URL, bundleURL: URL = Bundle.main.bundleURL) async throws -> URL {
        guard !deviceID.isEmpty else { throw CodeFailure("Choose your iPhone in Orbit Mac first. Then export its pairing file here.") }
        let helper = try helper(in: bundleURL)
        let directory = root.appendingPathComponent("SetupPairing/" + UUID().uuidString)
        let file = directory.appendingPathComponent("iPhone.mobiledevicepairing")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Pairing material goes directly to this private file, never stdout.
            do { _ = try await OrbitCommand.run(helper.path, ["--export-pairing", deviceID, file.path]) }
            catch let error as CodeFailure { throw error }
            catch { throw CodeFailure(missingHelperMessage) }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 2 * 1024 * 1024 else {
                throw CodeFailure("The pairing file wasn’t saved safely. Try exporting it again.")
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if let failure = error as? CodeFailure { throw failure }
            throw CodeFailure("Couldn’t save the pairing file on this Mac. Check access to Orbit’s setup folder and try again.")
        }
    }
}
