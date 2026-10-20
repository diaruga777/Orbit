import XCTest
@testable import OrbitCore
@testable import OrbitMac

final class CodeNightlyBuildTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var calendar: Calendar { var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(secondsFromGMT: 0)!; return result }
    func testWindowDailyLimitDefaultsAndDST() {
        var app = CodeBuildApp(project: CodeProject(path: "/App.xcodeproj", scheme: "App"), name: "App", bundleID: "app")
        let night = date("2026-10-19T02:00:00Z")
        XCTAssertFalse(CodeNightlySchedule.isDue(app, at: night, calendar: calendar))
        app.nightlyEnabled = true
        XCTAssertTrue(CodeNightlySchedule.isDue(app, at: night, calendar: calendar))
        for hour in ["00", "06", "12", "23"] {
            XCTAssertFalse(CodeNightlySchedule.isDue(app, at: date("2026-10-19T\(hour):00:00Z"), calendar: calendar))
        }
        app.lastNightlyAttempt = night
        XCTAssertFalse(CodeNightlySchedule.isDue(app, at: night.addingTimeInterval(3600), calendar: calendar))
        XCTAssertTrue(CodeNightlySchedule.isDue(app, at: night.addingTimeInterval(86400), calendar: calendar))
        XCTAssertEqual(CodeNightlySchedule.nextStart(after: date("2026-10-19T08:00:00Z"), calendar: calendar), date("2026-10-20T01:00:00Z"))
        var ny = calendar; ny.timeZone = TimeZone(identifier: "America/New_York")!
        // Repeating 1 AM on the fall-back night still means one build per local day.
        XCTAssertEqual(CodeNightlySchedule.requestID(app: app, peer: "mac", date: date("2026-11-01T05:30:00Z"), calendar: ny),
                       CodeNightlySchedule.requestID(app: app, peer: "mac", date: date("2026-11-01T06:30:00Z"), calendar: ny))
    }
    func testHistoryKeepsCompileSuccessEvenWhenInstallFailsAndRefreshes() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CodeBuildCatalog(defaults: defaults)
        let app = CodeBuildApp(project: CodeProject(path: "/App.xcodeproj", scheme: "App"), name: "App", bundleID: "app")
        var alias = app; alias.project.scheme = "Alias"
        catalog.save([app, alias], peer: "mac")
        catalog.edit(key: app.key, peer: "mac") { $0.nightlyEnabled = true }
        var job = CodeJob(id: "built", title: "Build", state: .failed)
        job.projectKey = app.key; job.builtAt = date("2026-10-19T02:00:00Z"); job.commitHash = "abcdef123456"
        catalog.record(job, peer: "mac")
        catalog.merge([app, alias], path: app.project.path, peer: "mac")
        let rows = catalog.apps(peer: "mac")
        XCTAssertEqual(rows.first?.lastBuiltAt, job.builtAt)
        XCTAssertEqual(rows.first?.commitHash, job.commitHash)
        XCTAssertEqual(rows.first?.nightlyEnabled, true)
        XCTAssertNil(rows.last?.lastBuiltAt)
        job.builtAt = date("2026-10-18T02:00:00Z"); catalog.record(job, peer: "mac")
        XCTAssertNotEqual(catalog.apps(peer: "mac").first?.lastBuiltAt, job.builtAt)
        XCTAssertTrue(catalog.apps(peer: "other").isEmpty)
        let old = Data(#"{"project":{"path":"/App.xcodeproj","scheme":"App","appID":"","groupID":""},"name":"App","bundleID":"app","branch":"main"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CodeBuildApp.self, from: old).nightlyEnabled)
    }
    @MainActor func testSubmitsAllSchemesWithoutWaitingAndOnlyOnceDaily() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CodeBuildCatalog(defaults: defaults), mac = NightlyMac()
        var app = CodeBuildApp(project: CodeProject(path: "/App.xcodeproj", scheme: "App"), name: "App", bundleID: "app")
        app.nightlyEnabled = true
        var alias = app; alias.project.scheme = "Alias"
        var off = app; off.project.scheme = "Off"; off.nightlyEnabled = nil
        catalog.save([app, alias, off], peer: "mac"); catalog.setDefaultDevice("phone", peer: "mac")
        let runner = CodeNightlyBuilds(catalog: catalog, client: CodeClient { try await mac.exchange($0) })
        let night = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date())!
        try await runner.run(peer: "mac", clock: { night })
        var requests = await mac.requests
        XCTAssertEqual(requests.filter { $0.operation == .runOnDevice }.count, 2)
        XCTAssertEqual(requests.filter { $0.operation == .runOnDevice }.map { $0.project?.scheme }, ["App", "Alias"])
        XCTAssertTrue(requests.filter { $0.operation == .runOnDevice }.allSatisfy { $0.deviceBuild?.installOnly == true && $0.deviceBuild?.monitorBundleID == nil && $0.deviceBuild?.deviceID == "phone" })
        try await runner.run(peer: "mac", clock: { night })
        requests = await mac.requests
        XCTAssertEqual(requests.filter { $0.operation == .runOnDevice }.count, 2, "Queued builds must survive runtime expiration without duplicate submissions")
        XCTAssertNotEqual(catalog.apps(peer: "mac")[0].jobID, catalog.apps(peer: "mac")[1].jobID)
    }
    @MainActor func testOldMacIsRejectedBeforeSubmittingOrLaunching() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mac = NightlyMac(supported: false)
        let runner = CodeNightlyBuilds(catalog: CodeBuildCatalog(defaults: defaults), client: CodeClient { try await mac.exchange($0) })
        do { try await runner.run(peer: "mac"); XCTFail("Must reject older companions") } catch {}
        let requests = await mac.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.operation, .devices)
    }
    func testMacQueuesAndCompletesAllAcceptedOvernightJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = try CodeJobs(root: root.appendingPathComponent("Jobs"))
        var first = CodeRequest(.runOnDevice); first.project = CodeProject(path: project.path, scheme: "One")
        first.deviceBuild = CodeDeviceBuild(deviceID: "phone"); first.deviceBuild?.installOnly = true
        var second = first; second.id = "second"; second.project?.scheme = "Two"
        let accepted = try await jobs.enqueueForTest([first, second])
        XCTAssertEqual(accepted.count, 2)
        XCTAssertEqual(accepted[1].progress?.stage, "Waiting for another Mac build…")
        // The fixture isn't a Git repository: both builds should fail in order
        // without leaving the second accepted job stuck in the queue.
        for _ in 0..<100 {
            if try await jobs.status(accepted[1].id).state != .running { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let final = try await jobs.status(accepted[1].id)
        XCTAssertEqual(final.state, .failed)
    }
    func testMacRestoresRequestIDsAndHistoryFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var job = CodeJob(id: "built", title: "Build", state: .succeeded)
        let app = CodeBuildApp(project: CodeProject(path: "/App.xcodeproj", scheme: "App"), name: "App", bundleID: "app")
        job.projectKey = app.key; job.requestID = "stable"; job.builtAt = Date(); job.commitHash = "abcdef"
        try JSONEncoder().encode(job).write(to: root.appendingPathComponent("built.json"))
        let jobs = try CodeJobs(root: root)
        var request = CodeRequest(.runOnDevice); request.id = "stable"
        let restored = try await jobs.start(request)
        XCTAssertEqual(restored, job, "Lost acknowledgements must not create a second build after restart")
        let rows = await jobs.history([app]); XCTAssertEqual(rows.first?.commitHash, "abcdef")
    }
}
private actor NightlyMac {
    var requests: [CodeRequest] = []
    let supported: Bool
    init(supported: Bool = true) { self.supported = supported }
    func exchange(_ data: Data) throws -> Data {
        let request = try JSONDecoder().decode(CodeRequest.self, from: data); requests.append(request)
        var response = CodeResponse()
        switch request.operation {
        case .devices: response.supportsOvernightBuilds = supported; response.devices = []
        case .runOnDevice: response.job = CodeJob(id: request.id, title: "Queued")
        case .job: response.job = CodeJob(id: request.jobID, title: "Queued")
        default: throw CodeFailure("Unexpected request")
        }
        return try JSONEncoder().encode(response)
    }
}

private extension CodeJobs {
    func enqueueForTest(_ requests: [CodeRequest]) throws -> [CodeJob] {
        // No actor suspension between admissions, just as consecutive RPCs
        // arrive while the first job is awaiting a Mac process.
        try requests.map { try start($0) }
    }
}
