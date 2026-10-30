import XCTest
@testable import OrbitHost

final class OrbitPairingExportTests: XCTestCase {
    private func fixture(_ body: String? = nil) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-export-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("Orbit.app")
        let helper = bundle.appendingPathComponent("Contents/Helpers/orbit-apple-adapter")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let body {
            try ("#!/bin/sh\n" + body).write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        }
        return (root, bundle)
    }
    func testMissingAndNonExecutableHelperExplainMacRepairWithoutCreatingExport() async throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for executable in [false, true] {
            if executable { try Data().write(to: bundle.appendingPathComponent("Contents/Helpers/orbit-apple-adapter")) }
            do {
                _ = try await OrbitPairingExport.export(deviceID: "fixture-phone", root: root, bundleURL: bundle)
                XCTFail("Missing helper was accepted")
            } catch { XCTAssertEqual(error.localizedDescription, OrbitPairingExport.missingHelperMessage) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SetupPairing").path))
    }
    func testNoSelectedPhoneIsReportedBeforeLookingForHelper() async throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await OrbitPairingExport.export(deviceID: "", root: root, bundleURL: bundle)
            XCTFail("Empty phone accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Choose your iPhone")) }
    }
    func testExportUsesOnlySelectedPhoneAndKeepsFilesPrivateAndIndependent() async throws {
        let (root, bundle) = try fixture("""
        [ "$1" = '--export-pairing' ] && [ "$2" = 'fixture-phone' ] || exit 1
        printf 'synthetic pairing fixture' > "$3"
        chmod 600 "$3"
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await OrbitPairingExport.export(deviceID: "fixture-phone", root: root, bundleURL: bundle)
        let second = try await OrbitPairingExport.export(deviceID: "fixture-phone", root: root, bundleURL: bundle)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "synthetic pairing fixture")
        for file in [first, second] {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            let parentMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600); XCTAssertEqual(parentMode?.intValue, 0o700)
        }
    }
    func testFailedAndUnsafeExportsAreRemovedAndTrustMessageIsPreserved() async throws {
        for body in ["printf partial > \"$3\"; echo 'Unlock your iPhone and tap Trust.' >&2; exit 1", "printf fixture > \"$3\"; chmod 644 \"$3\""] {
            let (root, bundle) = try fixture(body)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try await OrbitPairingExport.export(deviceID: "fixture-phone", root: root, bundleURL: bundle)
                XCTFail("Unsafe/failed export was accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(body.contains("exit 1") ? "Trust" : "saved safely"))
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("SetupPairing").path).isEmpty)
        }
    }
    func testBuiltAppIncludesSignedHelperAndNoticesWithoutAccessingPairingDaemon() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_TEST_PAIRING_APP"] else {
            throw XCTSkip("Supply an Xcode or packaged Mac app through ORBIT_TEST_PAIRING_APP.")
        }
        let bundle = URL(fileURLWithPath: path)
        let helper = try OrbitPairingExport.helper(in: bundle)
        _ = try await OrbitCommand.run("/usr/bin/codesign", ["--verify", "--strict", helper.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/AppleAdapterNotices/modules.json").path))
        do {
            // Invalid arguments return before reading any actual pairing record.
            _ = try await OrbitCommand.run(helper.path, ["--export-pairing"])
            XCTFail("Helper accepted missing arguments")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Choose your iPhone")) }
    }
}
