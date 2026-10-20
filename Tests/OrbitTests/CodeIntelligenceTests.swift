import XCTest
@testable import OrbitCore
@testable import OrbitMac

final class CodeIntelligenceTests: XCTestCase {
    func testMacServiceListsSchemesAndRunsBuildJob() async throws {
        guard let root = ProcessInfo.processInfo.environment["ORBIT_CODE_INTELLIGENCE_FIXTURE"] else { throw XCTSkip("Run scripts/test_code_intelligence.sh for the live Xcode integration.") }
        let service = try CodeService(root: URL(fileURLWithPath: root).appendingPathComponent("Service"))
        let client = CodeClient { await service.handle($0) }
        let project = CodeProject(path: root + "/Fixture.xcodeproj", scheme: "Fixture")
        let schemes = try await client.call(CodeRequest(.schemes, path: project.path))
        XCTAssertTrue(schemes.schemes.contains("Fixture"))
        XCTAssertTrue(schemes.schemes.contains("FixtureSupport"), "Include an automatic package library scheme in discovery")
        let allApps = try await client.call(CodeRequest(.apps, path: project.path))
        XCTAssertEqual(allApps.apps?.map(\.project.scheme), ["Fixture"], "A package scheme without a Build action must not abort the complete scan")
        var appRequest = CodeRequest(.apps, path: project.path); appRequest.project = project
        let apps = try await client.call(appRequest)
        XCTAssertEqual(apps.apps?.map(\.bundleID), ["dev.orbit.fixture"])
        XCTAssertEqual(apps.apps?.first?.project.scheme, "Fixture")
        var build = CodeRequest(.build); build.project = project
        // The submitting client can go away after acceptance. A fresh client
        // observes the same Mac-owned build and its persisted completion.
        var submittingClient: CodeClient? = CodeClient { await service.handle($0) }
        let response = try await submittingClient!.call(build)
        submittingClient = nil
        let reconnectedClient = CodeClient { await service.handle($0) }
        let started = try XCTUnwrap(response.job)
        var status = CodeRequest(.job); status.jobID = started.id
        var job = started
        for _ in 0..<120 {
            let response = try await reconnectedClient.call(status)
            job = try XCTUnwrap(response.job)
            if job.state != .running { break }
            try await Task.sleep(for: .seconds(1))
        }
        if job.state == .running {
            var cancel = CodeRequest(.cancel); cancel.jobID = job.id
            _ = try await client.call(cancel)
        }
        XCTAssertGreaterThan(job.progress?.completedTasks ?? 0, 0, "Real xcodebuild events must reach the persisted job")
        XCTAssertNotNil(job.progress?.reportedFraction)
        var legacyProgress = try XCTUnwrap(job.progress)
        legacyProgress.reportedFraction = nil // Simulate an older reader ignoring the new field.
        XCTAssertEqual(legacyProgress.fraction(), legacyProgress.fraction(at: Date().addingTimeInterval(1000)),
                       "Observed work must also remain fixed for older progress-aware clients")
        XCTAssertEqual(job.state, .succeeded, job.log)
        XCTAssertTrue(job.log.contains("BUILD SUCCEEDED"), job.log)
        let restarted = try CodeService(root: URL(fileURLWithPath: root).appendingPathComponent("Service"))
        let restored = try await CodeClient { await restarted.handle($0) }.call(status)
        XCTAssertEqual(restored.job?.state, .succeeded)
    }

    /// Opt-in integration test uses a disposable Xcode fixture built by
    /// scripts/test_code_intelligence.sh, never a user's working project.
    func testUIKitAndExternalModuleCompletionAndUnsavedDiagnostic() async throws {
        guard let root = ProcessInfo.processInfo.environment["ORBIT_CODE_INTELLIGENCE_FIXTURE"] else { throw XCTSkip("Run scripts/test_code_intelligence.sh for the live Xcode integration.") }
        let project = CodeProject(path: root + "/Fixture.xcodeproj", scheme: "Fixture")
        let server = try CodeLanguageServer(project: project, derivedData: URL(fileURLWithPath: root + "/DerivedData"), logs: URL(fileURLWithPath: root))
        try await server.initialize(project: project)
        let path = root + "/Main.swift"
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        var text = "import UIKit\nimport FixtureSupport\nlet label = UILabel()\nlabel."
        try server.update(path: path, text: text, version: 1)
        var uikit: [CodeCompletion] = []
        for attempt in 0..<10 {
            try server.update(path: path, text: text + String(repeating: "\n", count: attempt), version: attempt + 1)
            _ = try await server.diagnostics(path: path)
            uikit = try await server.complete(path: path, position: CodePosition(line: 3, character: 6))
            if uikit.contains(where: { $0.label.contains("textColor") }) { break }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(uikit.contains(where: { $0.label.contains("textColor") }), "UIKit completions: \(uikit.map(\.label).prefix(20))")
        text = "import UIKit\nimport FixtureSupport\nlet store = FixtureStore()\nstore."
        try server.update(path: path, text: text, version: 20)
        let external = try await server.complete(path: path, position: CodePosition(line: 3, character: 6))
        XCTAssertTrue(external.contains(where: { $0.label.contains("recordCount") }), "External completions: \(external.map(\.label))")
        try server.update(path: path, text: "import UIKit\nlet value: Int = \"wrong\"\n", version: 30)
        let diagnostics = try await server.diagnostics(path: path)
        XCTAssertTrue(diagnostics.contains(where: { $0.message.contains("String") && $0.message.contains("Int") }), "Diagnostics: \(diagnostics)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original, "Unsaved buffers must not alter Mac files")
    }
}
