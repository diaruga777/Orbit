import Foundation
import OrbitCore

/// Enrollment uses only the configured Code app's private container over an
/// existing Apple pairing. No host pairing keys are exported to the phone.
public struct CodeAppleEndpointContainer: CodeEndpointContainerAccess {
    private let root: URL
    private let bundleID: String
    public init(root: URL, bundleID: String) throws {
        guard bundleID.split(separator: ".").count >= 2, bundleID.count <= 255,
              bundleID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { throw CodeFailure("Configure the Orbit bundle identifier on your Mac.") }
        self.root = root; self.bundleID = bundleID
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    /// Public receipt identifies this installation's phone without granting any
    /// installation authority. Its fixed path survives app updates.
    public func writeInstallation(_ app: CodeInstalledApp) async throws {
        try await withDevice(app.deviceID) { scratch, process in
            let source = scratch.appendingPathComponent("installation.json")
            try JSONEncoder().encode(app).write(to: source, options: .atomic)
            _ = try await command(["device", "copy", "to", "--device", app.deviceID, "--source", source.path,
                "--destination", CodeInstalledApp.phoneReceiptPath, "--domain-type", "appDataContainer", "--domain-identifier", bundleID], scratch: scratch, process: process)
        }
    }
    public func writeChallenge(_ data: Data, id: String, deviceID: String) async throws {
        guard data.count <= 4096 else { throw CodeFailure("Invalid phone authorization challenge.") }
        let remote = try CodeEndpointEnrollment.path(id: id, proof: false)
        try await withDevice(deviceID) { scratch, process in
            let directory = scratch.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let source = directory.appendingPathComponent("challenge.json")
            try data.write(to: source); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
            _ = try await command(["device", "copy", "to", "--device", deviceID, "--source", source.path,
                                 "--destination", remote, "--domain-type", "appDataContainer", "--domain-identifier", bundleID], scratch: scratch, process: process)
        }
    }
    public func readProof(id: String, deviceID: String) async throws -> Data {
        let remote = try CodeEndpointEnrollment.path(id: id, proof: true)
        return try await withDevice(deviceID) { scratch, process in
            let destination = scratch.appendingPathComponent("proof.json")
            _ = try await command(["device", "copy", "from", "--device", deviceID, "--source", remote,
                                 "--destination", destination.path, "--domain-type", "appDataContainer", "--domain-identifier", bundleID], scratch: scratch, process: process)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8192 else { throw CodeFailure("Invalid phone authorization proof.") }
            return try Data(contentsOf: destination)
        }
    }
    /// Fixed, bounded journal files only. Never accept a path supplied by an app/agent.
    public func readDiagnosticFiles(deviceID: String) async throws -> [Data] {
        try await withDevice(deviceID) { scratch, process in
            var files: [Data] = []
            // Oldest first, so appends preserve the action sequence after reconnect.
            for index in (0..<4).reversed() {
                let name = index == 0 ? "events.jsonl" : "events.\(index).jsonl"
                let destination = scratch.appendingPathComponent(name)
                do {
                    _ = try await command(["device", "copy", "from", "--device", deviceID,
                        "--source", "Library/Application Support/OrbitAppDiagnostics/" + name,
                        "--destination", destination.path, "--domain-type", "appDataContainer",
                        "--domain-identifier", bundleID], scratch: scratch, process: process)
                } catch {
                    if index == 0 { throw error }
                    continue // A journal need not have rotated yet.
                }
                let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? Int.max) <= 1024 * 1024 + 16384 else {
                    throw CodeFailure("App diagnostic file exceeded its limit.")
                }
                files.append(try Data(contentsOf: destination))
            }
            return files
        }
    }
    private func withDevice<T>(_ device: String, operation: (URL, CodeProcess) async throws -> T) async throws -> T {
        let lock = CodeDeviceInstallLock.shared; let token = try await lock.acquire(device)
        defer { Task { await lock.release(device, token: token) } }
        let scratch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = CodeProcess()
        let details = try await command(["device", "info", "details", "--device", device], scratch: scratch, process: process)
        let result = details["result"] as? [String: Any] ?? [:]
        let properties = result["properties"] as? [String: Any] ?? [:]
        let hardware = properties["hardware"] as? [String: Any] ?? result["hardwareProperties"] as? [String: Any] ?? [:]
        guard hardware["udid"] as? String == device, hardware["reality"] as? String == "physical" else { throw CodeFailure("The Apple connection doesn’t match the selected physical phone.") }
        return try await operation(scratch, process)
    }
    private func command(_ arguments: [String], scratch: URL, process: CodeProcess) async throws -> [String: Any] {
        let prefix = scratch.appendingPathComponent(UUID().uuidString)
        let json = prefix.appendingPathExtension("json")
        let exit = try await process.run("/usr/bin/xcrun", ["devicectl"] + arguments + ["--timeout", "20", "--json-output", json.path], directory: scratch.path, log: prefix.appendingPathExtension("log"), timeout: 30)
        guard let size = try json.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128_000 else { throw CodeFailure("Apple returned an invalid phone authorization response.") }
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any] ?? [:]
        guard exit == 0, (result["info"] as? [String: Any])?["outcome"] as? String == "success" else { throw CodeFailure("Couldn’t authorize this phone. Connect it to your Mac, check device trust in Xcode, then try again.") }
        return result
    }
}
