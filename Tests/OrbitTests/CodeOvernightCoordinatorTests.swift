import XCTest
@testable import OrbitCore

final class CodeOvernightCoordinatorTests: XCTestCase {
    @MainActor func testLostAcceptanceReplyUsesSameIDAndManualRetryUsesNewID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let catalog = CodeBuildCatalog(defaults: defaults), journal = try CodeOvernightStore(root: root), mac = OvernightCoordinatorMac()
        var app = CodeBuildApp(project: CodeProject(path: "/App.xcodeproj", scheme: "App"), name: "App", bundleID: "app", deviceID: "phone")
        app.nightlyEnabled = true; catalog.save([app], peer: "mac")
        let runner = CodeOvernightCoordinator(catalog: catalog, client: CodeClient { try await mac.exchange($0) }, journal: journal)
        let invocation = CodeOvernightInvocation(reason: "background")
        try journal.save(invocation)
        let date = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date())!, policy = CodeOvernightPolicy()
        do { _ = try await runner.run(peer: "mac", invocationID: invocation.id, policy: policy, at: date); XCTFail("lost reply") } catch {}
        _ = try await runner.run(peer: "mac", invocationID: invocation.id, policy: policy, at: date)
        let ids = await mac.submitIDs
        XCTAssertEqual(ids.count, 2); XCTAssertEqual(ids[0], ids[1])
        _ = try await runner.run(peer: "mac", invocationID: invocation.id, policy: policy, manually: true, at: date)
        let retried = await mac.submitIDs; XCTAssertEqual(retried.count, 3); XCTAssertNotEqual(retried[1], retried[2])
    }
    @MainActor func testOlderReadyArtifactIsRetriedBeforeSubmittingNewScheme() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let catalog = CodeBuildCatalog(defaults: defaults), journal = try CodeOvernightStore(root: root), mac = OvernightCoordinatorMac()
        var app = CodeBuildApp(project: CodeProject(path: "/App.xcodeproj", scheme: "App"), name: "App", bundleID: "app", deviceID: "phone")
        app.nightlyEnabled = true
        var other = app; other.project.scheme = "Other"
        var off = app; off.project.scheme = "Off"; off.nightlyEnabled = false
        catalog.save([app, other, off], peer: "mac")
        let target = CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: app.project, branch: "main", generation: "g")
        var ready = CodeOvernightJob(requestID: "old", invocationID: "old", target: target)
        ready.state = .unknownCompletion
        ready.artifact = CodeBuildArtifact(id: "artifact", jobID: "compile", target: target, bundleID: "app", version: "1", build: "2", commit: "abc", digest: "digest", signingAuthority: "team", byteCount: 1)
        await mac.setJobs([ready]); await mac.setLosing(false)
        let runner = CodeOvernightCoordinator(catalog: catalog, client: CodeClient { try await mac.exchange($0) }, journal: journal)
        _ = try await runner.run(peer: "mac", invocationID: "wake", policy: CodeOvernightPolicy(), manually: true)
        let requests = await mac.operations
        XCTAssertEqual(requests, [.overnightCapabilities, .overnightStatus, .overnightInstall, .overnightSubmit])
        let schemes = await mac.schemes; XCTAssertEqual(schemes, ["Other"])
    }
}
private actor OvernightCoordinatorMac {
    var submitIDs: [String] = [], schemes: [String] = []
    var operations: [CodeRequest.Operation] = []
    private var jobs: [CodeOvernightJob] = []
    private var losing = true
    func setJobs(_ value: [CodeOvernightJob]) { jobs = value }
    func setLosing(_ value: Bool) { losing = value }
    func exchange(_ data: Data) throws -> Data {
        let request = try JSONDecoder().decode(CodeRequest.self, from: data); operations.append(request.operation)
        var response = CodeResponse()
        switch request.operation {
        case .overnightCapabilities: response.overnightCapabilities = CodeOvernightCapabilities()
        case .overnightStatus: response.overnightJobs = jobs
        case .overnightInstall: response.overnightJobs = jobs
        case .overnightSubmit:
            submitIDs.append(request.id); schemes.append(request.overnight!.target.project.scheme)
            if losing { losing = false; throw CodeFailure("Lost reply") }
            var failed = CodeOvernightJob(requestID: request.id, invocationID: request.overnight!.invocationID, target: request.overnight!.target)
            failed.state = .failed // Completed failures permit explicit manual retry.
            response.overnightJobs = [failed]
        default: throw CodeFailure("Unexpected request")
        }
        return try JSONEncoder().encode(response)
    }
}
