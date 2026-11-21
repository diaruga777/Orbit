#if DEBUG && targetEnvironment(simulator)
import UIKit
import OrbitCore
import OrbitUI
import OrbitTransport

/// Exercises the production Apps controller and monitor without a Mac or phone.
@MainActor enum OrbitTargetBuildPreview {
    static func make() throws -> UIViewController {
        let defaults = UserDefaults(suiteName: "Orbit.target-build-preview")!
        defaults.removePersistentDomain(forName: "Orbit.target-build-preview")
        if ProcessInfo.processInfo.arguments.contains("--target-cache-delayed") {
            let data = try JSONSerialization.data(withJSONObject: [["id": "cached", "name": "Cached App"]])
            OrbitPageCache(key: "Orbit.appsSnapshot", defaults: defaults).save(data, peer: "fixture-mac")
        }
        let legacyMac = ProcessInfo.processInfo.arguments.contains("--target-legacy-mac")
        let multiplePhones = ProcessInfo.processInfo.arguments.contains("--target-multiple-phones")
        let fixture = Fixture()
        let client = CodeClient { data in
            _ = try JSONDecoder().decode(CodeRequest.self, from: data)
            var response = CodeResponse()
            response.job = await fixture.status()
            return try JSONEncoder().encode(response)
        }
        let drafts = try CodeDraftStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("OrbitTargetBuildDrafts"))
        let environment = CodeEnvironment(client: client, drafts: drafts, defaults: defaults, browse: { _, _, _ in CodeBrowserPage(items: [], next: nil) }, pairing: { UIViewController() }, peerID: { "fixture-mac" }, jobStatus: { _ in
            try await fixture.loadStatus()
        })
        environment.builds.activated()
        let controller = OrbitTargetsController(rpc: { method, params in
            switch method {
            case "mac_update":
                await fixture.beginMacUpdate()
                return await fixture.macStatus()
            case "mac_update_status":
                if await fixture.macDisconnected() { throw CodeFailure("Fixture Mac is restarting") }
                return await fixture.macStatus()
            case "targets":
                if ProcessInfo.processInfo.arguments.contains("--target-cache-delayed") { try await Task.sleep(for: .seconds(8)) }
                if ProcessInfo.processInfo.arguments.contains("--target-list-retry"), await fixture.failList() { throw CodeFailure("Fixture Mac unavailable. Retry to load apps.") }
                if ProcessInfo.processInfo.arguments.contains("--target-list-empty") { return [[String: Any]]() }
                if ProcessInfo.processInfo.arguments.contains("--target-local-add") {
                    let added = await fixture.addedLocalApp
                    if !added { try await Task.sleep(for: .seconds(7)) }
                    return added ? [Self.localTarget] : []
                }
                var row: [String: Any] = ["id": "fixture", "name": "Fixture App", "enabled": await fixture.scheduled, "intervalHours": await fixture.intervalHours]
                if await fixture.started { row["jobID"] = "fixture-job" }
                if ProcessInfo.processInfo.arguments.contains("--target-no-wifi") { row["failure"] = "Build requests: \(await fixture.buildRequests)" }
                if ProcessInfo.processInfo.arguments.contains("--target-long-error"), !(await fixture.started) { row["failure"] = Self.longError }
                return await fixture.removed ? [[String: Any]]() : [row]
            case "projects_detect":
                let scan = await fixture.nextScan()
                try await Task.sleep(for: .seconds(scan > 1 ? 5 : 1))
                return scan > 1 ? [Self.localPath, Self.newPath] : [Self.localPath]
            case "project_summaries":
                guard let paths = params["paths"] as? [String], await fixture.claimNewProjects(paths) else {
                    throw CodeFailure("Fixture received a repeat preview request")
                }
                let rows = paths.map { path in
                    OrbitProjectSummary(path: path, name: path == Self.localPath ? "Local Notes" : "New Timer",
                                        iconPNG: UIImage(systemName: "note.text")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal).pngData())
                }
                return try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows))
            case "project_preview":
                let app = CodeBuildApp(project: CodeProject(path: Self.localPath, scheme: "Notes"), name: "Local Notes",
                                       bundleID: "example.fixture.notes", branch: "develop")
                return try JSONSerialization.jsonObject(with: JSONEncoder().encode([app]))
            case "devices":
                guard legacyMac, await fixture.legacyAddRejected else { throw CodeFailure("Unexpected phone discovery") }
                let phone = ["id": "fixture-phone", "name": "Fixture Phone"]
                return multiplePhones ? [phone, ["id": "other-phone", "name": "Other Phone"]] : [phone]
            case "target_add":
                guard params["project"] as? String == Self.localPath, params["scheme"] as? String == "Notes",
                      params["branch"] as? String == "develop", params["intervalHours"] as? Int == 144,
                      params["trust"] as? Bool == true, params["enabled"] as? Bool == true else {
                    throw CodeFailure("Unexpected registration defaults")
                }
                if legacyMac {
                    if params["deviceID"] == nil {
                        await fixture.rejectLegacyAdd()
                        throw CodeFailure("Provide deviceID.")
                    }
                    guard !multiplePhones, params["deviceID"] as? String == "fixture-phone", await fixture.legacyAddRejected else {
                        throw CodeFailure("Unexpected phone for registration")
                    }
                } else if params["deviceID"] != nil { throw CodeFailure("Unexpected phone override") }
                try await Task.sleep(for: .seconds(4))
                await fixture.addLocalApp()
                return Self.localTarget
            case "schedule":
                await fixture.schedule(enabled: params["enabled"] as? Bool == true, hours: params["intervalHours"] as? Int ?? 144)
                return ["ok": true]
            case "target_remove": await fixture.remove(); return ["ok": true]
            case "build":
                if ProcessInfo.processInfo.arguments.contains("--target-build-request-failure") { throw CodeFailure("Fixture build request failed. Try again when your Mac is ready.") }
                guard params["monitorBundleID"] as? String == Bundle.main.bundleIdentifier else { throw CodeFailure("Missing self-update monitor identity") }
                await fixture.begin()
                return try JSONSerialization.jsonObject(with: JSONEncoder().encode(await fixture.status()))
            case "job": return try JSONSerialization.jsonObject(with: JSONEncoder().encode(try await fixture.loadStatus()))
            default: throw CodeFailure("Unexpected preview request")
            }
        }, monitor: environment.builds, peerID: { "fixture-mac" }, refreshInterval: ProcessInfo.processInfo.arguments.contains("--target-list-retry") ? 60 : 3, preparePhoneInstall: {
            if ProcessInfo.processInfo.arguments.contains("--target-no-wifi"), await fixture.wifiUnavailable() { throw OrbitInstallNetwork.WiFiRequired() }
        }, defaults: defaults)
        return UINavigationController(rootViewController: controller)
    }
    private static let localPath = "/Users/fixture/Development/Notes/Notes.xcodeproj"
    private static let newPath = "/Users/fixture/Development/Timer/Timer.xcworkspace"
    private static let localTarget: [String: Any] = ["id": "local-notes", "name": "Local Notes", "enabled": true, "intervalHours": 144]
    static let longError = "Fixture compilation failed.\n" + (1...80).map { "Diagnostic \($0): Check the app’s build settings and try again." }.joined(separator: "\n")
    actor Fixture {
        private var scans = 0
        private var summarizedProjects: Set<String> = []
        private(set) var legacyAddRejected = false
        private(set) var addedLocalApp = false
        func nextScan() -> Int { scans += 1; return scans }
        func claimNewProjects(_ paths: [String]) -> Bool {
            guard summarizedProjects.isDisjoint(with: paths) else { return false }
            summarizedProjects.formUnion(paths)
            return true
        }
        func addLocalApp() { addedLocalApp = true }
        func rejectLegacyAdd() { legacyAddRejected = true }
        var scheduled = false
        var intervalHours = 144
        var removed = false
        func schedule(enabled: Bool, hours: Int) { scheduled = enabled; intervalHours = hours }
        private var stopped = false
        func remove() { removed = true; stopped = started }
        private var macStarted: Date?
        func beginMacUpdate() { macStarted = Date() }
        func macDisconnected() -> Bool {
            guard let macStarted else { return false }
            return Date().timeIntervalSince(macStarted) > 2 && Date().timeIntervalSince(macStarted) < 6
        }
        func macStatus() -> [String: Any] {
            guard let macStarted else { return ["available": true, "stage": "Build the latest saved commit on your Mac."] }
            let done = Date().timeIntervalSince(macStarted) > 7
            let failed = ProcessInfo.processInfo.arguments.contains("--target-mac-update-failure")
            return ["available": true, "id": "mac-fixture", "state": done ? (failed ? "failed" : "succeeded") : "building",
                    "stage": done ? (failed ? "Fixture Mac signing failed." : "Orbit Mac is up to date.") : "Building committed source…",
                    "log": "Fixture Mac build output\n"]
        }
        private var networkChecks = 0
        private(set) var buildRequests = 0
        func wifiUnavailable() -> Bool { networkChecks += 1; return networkChecks <= 2 }
        var started = false
        private var listFailed = false
        func failList() -> Bool { if listFailed { return false }; listFailed = true; return true }
        private var start = Date()
        func begin() { buildRequests += 1; started = true; start = Date() }
        func loadStatus() throws -> CodeJob {
            let elapsed = Date().timeIntervalSince(start)
            if ProcessInfo.processInfo.arguments.contains("--target-build-disconnect"), elapsed > 3, elapsed < 7 {
                throw CodeFailure("Fixture Mac unavailable")
            }
            return status()
        }
        func status() -> CodeJob {
            var job = CodeJob(id: "fixture-job", title: "Build & Install · Fixture App")
            job.startedAt = start
            let elapsed = max(0, Date().timeIntervalSince(start))
            let fraction = min(0.79, 0.25 + elapsed * 0.025)
            job.progress = CodeJobProgress(stage: "Compile Feature.swift", start: fraction, end: fraction, estimatedSeconds: 1, reportedFraction: fraction)
            job.progress?.completedTasks = Int(elapsed * 5); job.progress?.activeTasks = 2
            job.log = "Compile Feature.swift\nFixture build output\n"
            if stopped { job.state = .cancelled }
            else if elapsed > 18 {
                if ProcessInfo.processInfo.arguments.contains("--target-build-failure") {
                    job.state = .failed; job.failureMessage = "Fixture compilation failed. Open the console for details."
                } else { job.state = .succeeded }
            }
            return job
        }
    }
}
#endif
