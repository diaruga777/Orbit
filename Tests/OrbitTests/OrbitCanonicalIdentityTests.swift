import XCTest
import OrbitCore
@testable import OrbitHost
@testable import OrbitMac

final class OrbitCanonicalIdentityTests: XCTestCase {
    func testSourceCompanionRepairsStaleCatalogAndPreservesCanonicalExactBundle() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let localBefore = try Data(contentsOf: fixture.source.appendingPathComponent("Config/Local.xcconfig"))
        var legacy = fixture.legacyTarget
        legacy.lastSuccess = Date(); legacy.lastJobID = "old-install"
        try JSONEncoder().encode([legacy]).write(to: fixture.root.appendingPathComponent("targets.json"))
        var config = OrbitConfiguration(); config.phoneBundleID = "dev.test.generated.ios"
        try JSONEncoder().encode(config).write(to: fixture.root.appendingPathComponent("config.json"))
        let host = try OrbitHost(root: fixture.root, canonicalSource: fixture.source)
        let rows = try JSONSerialization.jsonObject(with: await host.handle(Data(#"{"method":"targets"}"#.utf8))) as? [String: Any]
        let target = try XCTUnwrap((rows?["result"] as? [[String: Any]])?.first)
        let project = try XCTUnwrap(target["project"] as? [String: Any])
        XCTAssertEqual(target["id"] as? String, legacy.id)
        XCTAssertEqual(target["deviceID"] as? String, legacy.deviceID)
        XCTAssertEqual(target["lastJobID"] as? String, "old-install")
        XCTAssertNil(target["lastSuccess"])
        XCTAssertEqual(project["path"] as? String, fixture.source.appendingPathComponent("Orbit.xcodeproj").path)
        XCTAssertEqual(project["iosBundleID"] as? String, fixture.bundle)
        XCTAssertEqual(project["bundlePrefix"] as? String, "dev.test.canonical")
        let saved = try JSONDecoder().decode(OrbitConfiguration.self, from: Data(contentsOf: fixture.root.appendingPathComponent("config.json")))
        XCTAssertEqual(saved.phoneBundleID, fixture.bundle)
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("Config/Local.xcconfig")), localBefore)
        // A build from the accidentally installed copy must stop before any job submission.
        let request = try JSONSerialization.data(withJSONObject: ["method": "build", "params": ["id": legacy.id, "monitorBundleID": "dev.test.generated.ios"]])
        let rejected = try JSONSerialization.jsonObject(with: await host.handle(request)) as? [String: Any]
        XCTAssertTrue((rejected?["error"] as? String)?.contains("different Orbit app") == true)
    }

    func testWizardUsesCanonicalCheckoutAndExactIdentityInsteadOfGeneratingAnotherApp() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let setup = OrbitSetup(root: fixture.root, canonicalSource: fixture.source)
        var stale = OrbitSetupState(); stale.bundlePrefix = "dev.test.generated"; stale.source = fixture.legacySource.path
        stale.installed = true; stale.installJobID = "duplicate-install"
        try await setup.save(stale)
        let state = try await setup.load()
        XCTAssertEqual(state.bundlePrefix, "dev.test.canonical")
        XCTAssertEqual(state.iosBundleID, fixture.bundle)
        XCTAssertEqual(state.teamID, "ABCDEFGHIJ")
        XCTAssertFalse(state.installed)
        XCTAssertNil(state.installJobID)
        let source = try await setup.prepareSource()
        XCTAssertEqual(source, fixture.source)
        let host = try OrbitHost(root: fixture.root, canonicalSource: fixture.source)
        let request = try JSONSerialization.data(withJSONObject: ["method": "setup_phone", "params": ["bundlePrefix": state.bundlePrefix, "bundleID": fixture.bundle]])
        let response = try JSONSerialization.jsonObject(with: await host.handle(request)) as? [String: Any]
        XCTAssertNil(response?["error"])
        XCTAssertEqual((response?["result"] as? [String: Any])?["bundleID"] as? String, fixture.bundle)
    }

    func testActiveLegacyBuildIsNotSilentlyRebound() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var target = fixture.legacyTarget; target.jobID = "active"
        var targets = [target]; var config = OrbitConfiguration(); config.phoneBundleID = "dev.test.generated.ios"
        XCTAssertThrowsError(try OrbitPhoneIdentity.reconcile(root: fixture.root, source: fixture.source, configuration: &config, targets: &targets))
        XCTAssertEqual(targets[0].project, target.project)
        XCTAssertEqual(config.phoneBundleID, "dev.test.generated.ios")
    }

    func testSelfBuildMustMatchBothConfiguredAndRequestingPhoneIdentities() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = try OrbitPhoneIdentity.project(at: fixture.source)
        XCTAssertNoThrow(try CodeOrbitIdentity.verify(bundleID: fixture.bundle, project: project, phoneBundleID: fixture.bundle, monitorBundleID: fixture.bundle))
        XCTAssertThrowsError(try CodeOrbitIdentity.verify(bundleID: fixture.bundle, project: project, phoneBundleID: "dev.test.generated.ios", monitorBundleID: fixture.bundle))
        XCTAssertThrowsError(try CodeOrbitIdentity.verify(bundleID: fixture.bundle, project: project, phoneBundleID: fixture.bundle, monitorBundleID: "dev.test.generated.ios"))
        let other = CodeProject(path: fixture.source.appendingPathComponent("Other.xcodeproj").path, scheme: "Other")
        XCTAssertNoThrow(try CodeOrbitIdentity.verify(bundleID: "dev.test.other", project: other, phoneBundleID: fixture.bundle, monitorBundleID: fixture.bundle))
    }

    func testRetainedWrongIdentityFailsBeforeArtifactAccessOrInstallation() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = CodeOvernightTarget(peerID: "mac", deviceID: "inert-phone", project: fixture.legacyTarget.project, branch: "main", generation: "g")
        var job = CodeOvernightJob(requestID: "old", invocationID: "old", target: target)
        job.state = .waitingForPhone
        job.artifact = CodeBuildArtifact(id: UUID().uuidString, jobID: "compile", target: target,
            bundleID: "dev.test.generated.ios", version: "1", build: "1", commit: "abc", digest: "unused", signingAuthority: "unused", byteCount: 0)
        let store = try CodeOvernightStore(root: fixture.root.appendingPathComponent("Overnight")); try store.save(job)
        let service = try CodeOvernightService(root: fixture.root, builds: CodeJobs(root: fixture.root.appendingPathComponent("Jobs")), phoneBundleID: fixture.bundle)
        _ = try await service.retryInstall(job.id)
        for _ in 0..<100 {
            if let result = try await service.status().first, result.state == .failed {
                XCTAssertEqual(result.error?.stage, "identity")
                XCTAssertTrue(result.installs.isEmpty)
                XCTAssertNil(result.installedAt)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Wrong-identity artifact did not reach a durable failure")
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var source: URL { root.appendingPathComponent("Canonical") }
        var legacySource: URL { root.appendingPathComponent("PhoneSource/old") }
        let bundle = "dev.test.existing-phone"
        var legacyTarget: OrbitTarget {
            var project = CodeProject(path: legacySource.appendingPathComponent("Orbit.xcodeproj").path, scheme: "Orbit")
            project.bundlePrefix = "dev.test.generated"; project.developmentTeam = "ABCDEFGHIJ"
            return OrbitTarget(name: "Orbit", project: project, deviceID: "inert-phone")
        }
        init() throws {
            for folder in [source, legacySource] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("Config"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("Orbit.xcodeproj"), withIntermediateDirectories: true)
                try Data().write(to: folder.appendingPathComponent("Config/Orbit.xcconfig"))
            }
            let config = try CodeOrbitIdentity.localConfiguration(bundlePrefix: "dev.test.canonical", developmentTeam: "ABCDEFGHIJ", iosBundleID: bundle)
            try Data(config.utf8).write(to: source.appendingPathComponent("Config/Local.xcconfig"))
        }
    }
}
