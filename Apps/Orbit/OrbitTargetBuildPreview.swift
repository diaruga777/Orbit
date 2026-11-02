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
                var row: [String: Any] = ["id": "fixture", "name": "Fixture App", "enabled": false]
                if await fixture.started { row["jobID"] = "fixture-job" }
                if ProcessInfo.processInfo.arguments.contains("--target-no-wifi") { row["failure"] = "Build requests: \(await fixture.buildRequests)" }
                return [row]
            case "build":
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
    actor Fixture {
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
            if elapsed > 18 {
                if ProcessInfo.processInfo.arguments.contains("--target-build-failure") {
                    job.state = .failed; job.failureMessage = "Fixture compilation failed. Open the console for details."
                } else { job.state = .succeeded }
            }
            return job
        }
    }
}
#endif
