import XCTest
import OrbitCore
import OrbitWire
import OrbitTransport
@testable import OrbitHost
@testable import OrbitMac

final class OrbitHostTests: XCTestCase {
    func testTargetIconsBackfillOlderCatalogAndSurviveRestart() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = CodeProject(path: "/repo/App.xcodeproj", scheme: "App")
        let legacy = OrbitTarget(name: "App", project: project, deviceID: "phone")
        let secondPhone = OrbitTarget(name: "App", project: project, deviceID: "other-phone")
        let missing = OrbitTarget(name: "Missing", project: CodeProject(path: project.path, scheme: "Missing"), deviceID: "phone")
        let catalog = root.appendingPathComponent("targets.json")
        try JSONEncoder().encode([legacy, secondPhone, missing]).write(to: catalog)
        // Optional thumbnails keep the old catalog schema decodable.
        XCTAssertNil(try JSONDecoder().decode([OrbitTarget].self, from: Data(contentsOf: catalog))[0].iconPNG)
        let icon = Data([1, 2, 3])
        var host: OrbitHost? = try OrbitHost(root: root)
        await host!.populateMissingTargetIcons { queried in
            if queried.scheme == "Missing" { throw CodeFailure("Project unavailable") }
            var app = CodeBuildApp(project: queried, name: "App", bundleID: "example.app")
            app.iconPNG = icon
            return [app]
        }
        await host!.populateMissingTargetIcons { _ in
            XCTFail("Polling repeated icon discovery immediately")
            return []
        }
        host = nil
        let restarted = try OrbitHost(root: root)
        // Verify the real RPC sends base64 thumbnails and retains unavailable apps.
        await restarted.populateMissingTargetIcons { _ in [] }
        let response = await restarted.handle(Data(#"{"method":"targets"}"#.utf8))
        let result = try XCTUnwrap((JSONSerialization.jsonObject(with: response) as? [String: Any])?["result"] as? [[String: Any]])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0]["iconPNG"] as? String, icon.base64EncodedString())
        XCTAssertEqual(result[1]["iconPNG"] as? String, icon.base64EncodedString())
        XCTAssertNil(result[2]["iconPNG"])
    }
    func testBuildIconsUpdateCatalogEvenWhenInstallFailsAndSkipOlderResults() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let jobs = root.appendingPathComponent("Builds/Jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        let store = try CodeOvernightStore(root: root.appendingPathComponent("Builds/Overnight"))
        let project = CodeProject(path: "/repo/App.xcodeproj", scheme: "App")
        var rows: [OrbitTarget] = []
        for (name, retained) in [("direct", false), ("retained", true), ("newer-manual", false)] {
            var target = OrbitTarget(name: name, project: project, deviceID: "phone")
            target.iconPNG = Data([1])
            if name == "newer-manual" { target.iconUpdatedAt = Date() }
            var compilation = CodeJob(id: UUID().uuidString, title: name, state: .failed)
            compilation.appIcon = CodeBuildIcon(png: Data([2]), updatedAt: Date(timeIntervalSinceNow: -5))
            try JSONEncoder().encode(compilation).write(to: jobs.appendingPathComponent(compilation.id + ".json"))
            if retained {
                let identity = CodeOvernightTarget(peerID: "orbit-mac", deviceID: "phone", project: project, branch: "main", generation: target.id)
                var job = CodeOvernightJob(requestID: "retained", invocationID: "retained", target: identity)
                job.compilationJobID = compilation.id; job.state = .failed
                try store.save(job)
                target.jobID = job.id
            } else {
                target.jobID = compilation.id
            }
            target.jobKind = retained ? "retained" : "build"
            rows.append(target)
        }
        let catalog = root.appendingPathComponent("targets.json")
        try JSONEncoder().encode(rows).write(to: catalog)
        let host = try OrbitHost(root: root)
        await host.tick()
        let saved = try JSONDecoder().decode([OrbitTarget].self, from: Data(contentsOf: catalog))
        XCTAssertEqual(saved.map(\.iconPNG), [Data([2]), Data([2]), Data([1])])
        XCTAssertTrue(saved.allSatisfy { $0.jobID == nil && $0.lastSuccess == nil && $0.failure != nil })
    }
    func testSixDayCadenceDependsOnConfirmedInstallation() {
        let now = Date(timeIntervalSince1970: 2000000)
        var target = OrbitTarget(name: "App", project: CodeProject(path: "/repo/App.xcodeproj", scheme: "App"), deviceID: "phone", enabled: true)
        XCTAssertTrue(target.isDue(at: now))
        target.lastAttempt = now.addingTimeInterval(-60); XCTAssertFalse(target.isDue(at: now))
        target.lastAttempt = now.addingTimeInterval(-1801); XCTAssertTrue(target.isDue(at: now))
        target.lastSuccess = now.addingTimeInterval(-143 * 3600); XCTAssertFalse(target.isDue(at: now))
        target.lastSuccess = now.addingTimeInterval(-144 * 3600); XCTAssertTrue(target.isDue(at: now))
        target.jobID = "retained-job"; XCTAssertFalse(target.isDue(at: now))
    }
    func testPendingRequestAndSigningPolicySurviveRestart() throws {
        var project = CodeProject(path: "/repo/App.xcodeproj", scheme: "App")
        project.developmentTeam = "USERS_TEAM"; project.minimumProfileHours = 156
        var target = OrbitTarget(name: "App", project: project, deviceID: "phone")
        target.pendingRequest = CodeRequest(.overnightSubmit)
        let decoded = try JSONDecoder().decode(OrbitTarget.self, from: JSONEncoder().encode(target))
        XCTAssertEqual(decoded.pendingRequest?.id, target.pendingRequest?.id)
        XCTAssertEqual(decoded.project.developmentTeam, "USERS_TEAM")
        XCTAssertEqual(decoded.project.minimumProfileHours, 156)
        XCTAssertTrue(decoded.project.xcodeArguments.contains("DEVELOPMENT_TEAM=USERS_TEAM"))
    }
    func testGitHubInputCannotBecomeAnArbitraryCloneURL() throws {
        XCTAssertEqual(try OrbitGitHub.repository("https://github.com/example/app.git"), "example/app")
        XCTAssertEqual(try OrbitGitHub.repository("example/app"), "example/app")
        for input in ["https://evil.example/app", "https://github.com@evil.example/app", "../app", "owner/../app", "owner/app/extra", "--upload-pack=bad", "file:///tmp/repo", "https://user:password@github.com/owner/app"] {
            XCTAssertThrowsError(try OrbitGitHub.repository(input), input)
        }
    }
    func testUntrustedPeerCannotBrowseOrRunCommands() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var host: OrbitHost? = try OrbitHost(root: root)
        let data = await host!.handle(Data(#"{"method":"browse","params":{"path":"/"}}"#.utf8), peer: "stranger")
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(value?["error"])
        do { try await host!.trust("stranger"); XCTFail("No pairing window was open") } catch { }
        await host!.openPairing(); try await host!.trust("phone")
        host = nil
        let restarted = try OrbitHost(root: root)
        let trusted = await restarted.isTrusted("phone"); XCTAssertTrue(trusted)
        let other = await restarted.isTrusted("stranger"); XCTAssertFalse(other)
    }
    func testForgetRevokesAndDoesNotReopenPairing() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root); await host.openPairing(); try await host.trust("phone")
        _ = await host.handle(Data(#"{"method":"forget"}"#.utf8))
        let trusted = await host.isTrusted("phone"); XCTAssertFalse(trusted)
        do { try await host.trust("new-phone"); XCTFail("Forgetting must close pairing") } catch { }
    }
    func testMacTargetsRetainDeploymentAndJobsAcrossRestart() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var target = OrbitTarget(name: "Companion", project: CodeProject(path: "/repo/Package.swift", scheme: "Companion"), deviceID: "host-mac")
        target.mac = OrbitMacDeployment(installPath: "/Applications/Companion.app", bundleID: "test.fixture.mac", certificate: String(repeating: "A", count: 40), settings: Data("{}".utf8))
        target.jobID = UUID().uuidString; target.lastJobID = target.jobID; target.jobKind = "mac"
        try JSONEncoder().encode([target]).write(to: root.appendingPathComponent("targets.json"))
        let host = try OrbitHost(root: root)
        await host.populateMissingTargetIcons { _ in XCTFail("Mac apps must not invoke iOS discovery"); return [] }
        let response = await host.handle(Data(#"{"method":"targets"}"#.utf8))
        let value = try XCTUnwrap((JSONSerialization.jsonObject(with: response) as? [String: Any])?["result"] as? [[String: Any]])
        XCTAssertEqual((value[0]["mac"] as? [String: Any])?["installPath"] as? String, "/Applications/Companion.app")
        // An accepted catalog entry without dispatch must fail safely after restart.
        await host.tick()
        let restored = try JSONDecoder().decode([OrbitTarget].self, from: Data(contentsOf: root.appendingPathComponent("targets.json")))
        XCTAssertNil(restored[0].jobID)
        XCTAssertNil(restored[0].lastSuccess)
        XCTAssertNotNil(restored[0].failure)
        XCTAssertEqual(restored[0].mac?.certificate, target.mac?.certificate)
    }
    func testRemovalCancelsDurablePendingAndRetainedBuildsAndIgnoresStaleJobs() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeOvernightStore(root: root.appendingPathComponent("Builds/Overnight"))
        let project = CodeProject(path: "/unused/App.xcodeproj", scheme: "App")
        var queued = OrbitTarget(name: "Queued", project: project, deviceID: "phone", enabled: true)
        let identity = CodeOvernightTarget(peerID: "orbit-mac", deviceID: queued.deviceID, project: project, branch: "main", generation: queued.id)
        let accepted = CodeOvernightJob(requestID: "pending", invocationID: "pending", target: identity)
        try store.save(accepted)
        var request = CodeRequest(.overnightSubmit)
        request.id = accepted.requestID
        request.overnight = CodeOvernightSubmission(invocationID: request.id, target: identity, localDay: "fixture")
        queued.pendingRequest = request

        var active = OrbitTarget(name: "Active", project: project, deviceID: "other-phone", enabled: true)
        let activeIdentity = CodeOvernightTarget(peerID: "orbit-mac", deviceID: active.deviceID, project: project, branch: "main", generation: active.id)
        var building = CodeOvernightJob(requestID: "working", invocationID: "working", target: activeIdentity)
        building.state = .building
        try store.save(building)
        active.jobID = building.id
        active.jobKind = "retained"

        var failed = OrbitTarget(name: "Failed", project: project, deviceID: "third-phone")
        var failure = CodeOvernightJob(requestID: "failed", invocationID: "failed", target: identity)
        failure.state = .failed
        try store.save(failure)
        failed.jobID = failure.id
        failed.jobKind = "retained"
        var stale = OrbitTarget(name: "Stale", project: project, deviceID: "fourth-phone")
        stale.jobID = UUID().uuidString

        let catalog = root.appendingPathComponent("targets.json")
        try JSONEncoder().encode([queued, active, failed, stale]).write(to: catalog)
        let host = try OrbitHost(root: root)
        for target in [queued, active, failed, stale, stale] {
            let data = try JSONSerialization.data(withJSONObject: ["method": "target_remove", "params": ["id": target.id]])
            let reply = await host.handle(data)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
            XCTAssertEqual((object["result"] as? [String: String])?["removed"], target.id, "\(object)")
        }
        let persisted = try CodeOvernightStore(root: store.root).jobs()
        XCTAssertEqual(persisted.first { $0.id == accepted.id }?.state, .cancelled)
        XCTAssertEqual(persisted.first { $0.id == building.id }?.state, .cancelled)
        XCTAssertEqual(persisted.first { $0.id == failure.id }?.state, .failed)
        let job = await host.handle(try JSONSerialization.data(withJSONObject: ["method": "job", "params": ["id": building.id]]))
        let reply = try JSONSerialization.jsonObject(with: job) as? [String: Any]
        XCTAssertEqual((reply?["result"] as? [String: Any])?["state"] as? String, "cancelled")
        XCTAssertTrue(try JSONDecoder().decode([OrbitTarget].self, from: Data(contentsOf: catalog)).isEmpty)
    }

    func testMacRegistrationRequiresTrustBeforeReadingSource() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let data = await host.handle(Data(#"{"method":"target_add","params":{"platform":"macOS","project":"/missing/Package.swift","scheme":"Companion"}}"#.utf8))
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue((value?["error"] as? String)?.contains("trust=true") == true)
    }
    func testMacUncertainInstallationRemainsInProgress() throws {
        let job = try CodeJob.targetStatus(Data(#"{"id":"job","platform":"macOS","state":"unknownCompletion","failureMessage":"Check the installed app."}"#.utf8))
        XCTAssertEqual(job.state, .running)
        XCTAssertEqual(job.failureMessage, "Check the installed app.")
    }
    func testAddRequiresTrustBeforeInvokingXcode() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        let data = await host.handle(Data(#"{"method":"target_add","params":{"project":"/tmp/App.xcodeproj","scheme":"App","deviceID":"phone"}}"#.utf8))
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue((value?["error"] as? String)?.contains("trust=true") == true)
    }
    func testFramingRejectsOversizeBeforeReadingPayload() async throws {
        let (reader, writer) = PipeByteStream.pair(); defer { reader.close(); writer.close() }
        try await writer.write(Data([0xff, 0xff, 0xff, 0xff]))
        do { _ = try await OrbitRPC.read(from: reader); XCTFail("Oversized frame accepted") } catch { }
    }
    func testFramingHandlesFragmentedPayload() async throws {
        let (reader, writer) = PipeByteStream.pair(); defer { reader.close(); writer.close() }
        let task = Task { try await OrbitRPC.read(from: reader) }
        try await writer.write(Data([0, 0])); try await writer.write(Data([0, 5])); try await writer.write(Data("he".utf8)); try await writer.write(Data("llo".utf8))
        let value = try await task.value; XCTAssertEqual(value, Data("hello".utf8))
    }
    func testProfileRotationOnlySelectsMatchingExpiringAutomaticDevelopmentProfile() {
        let now = Date()
        let profile: [String: Any] = ["ExpirationDate": now.addingTimeInterval(3600), "TeamIdentifier": ["TEAM"], "ProvisionedDevices": ["phone"], "Entitlements": ["get-task-allow": true, "application-identifier": "TEAM.com.example.app"]]
        XCTAssertTrue(CodeProfileRefresh.matches(profile, bundle: "com.example.app", team: "TEAM", device: "phone", minimumHours: 156, at: now))
        XCTAssertFalse(CodeProfileRefresh.matches(profile, bundle: "com.other.app", team: "TEAM", device: "phone", minimumHours: 156, at: now))
        XCTAssertFalse(CodeProfileRefresh.matches(profile, bundle: "com.example.app", team: "OTHER", device: "phone", minimumHours: 156, at: now))
        XCTAssertFalse(CodeProfileRefresh.matches(profile, bundle: "com.example.app", team: "TEAM", device: "different-phone", minimumHours: 156, at: now))
        var fresh = profile; fresh["ExpirationDate"] = now.addingTimeInterval(168 * 3600)
        XCTAssertFalse(CodeProfileRefresh.matches(fresh, bundle: "com.example.app", team: "TEAM", device: "phone", minimumHours: 156, at: now))
    }
    func testDumbpipePairingCodePreservesPinnedIdentity() throws {
        let id = try DeviceID(bytes: Data(repeating: 42, count: 32))
        let endpoint = id.bytes.map { String(format: "%02x", $0) }.joined()
        let original = OrbitPairingCode(deviceID: id, addresses: [.dumbpipe(endpoint: endpoint)])
        let restored = try OrbitPairingCode(string: original.text)
        XCTAssertEqual(restored.deviceID, id); XCTAssertEqual(restored.addresses, original.addresses)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("OrbitTests-" + UUID().uuidString) }
}
