import XCTest
import OrbitCore

final class CodeTargetJobTests: XCTestCase {
    func testRetainedCompilationAndInstallationStayDistinct() throws {
        let target = CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: CodeProject(path: "/tmp/App.xcodeproj", scheme: "App"), branch: "main", generation: "test")
        var retained = CodeOvernightJob(requestID: "request", invocationID: "invocation", target: target)
        var compilation = CodeJob(id: "compile", title: "Build")
        compilation.progress = CodeJobProgress(stage: "Compile Feature.swift", start: 0.4, end: 0.4, estimatedSeconds: 1, reportedFraction: 0.4)
        compilation.progress?.completedTasks = 42
        retained.state = .building
        let progress = retained.monitoring(compilation: compilation)
        XCTAssertEqual(progress.progressStage, "Compile Feature.swift")
        XCTAssertEqual(progress.progressDetail, "42 build tasks completed")
        XCTAssertEqual(progress.id, retained.id)
        compilation.state = .succeeded
        for state: CodeOvernightJob.State in [.waitingForPhone, .installing, .unknownCompletion] {
            retained.state = state
            let job = retained.monitoring(compilation: compilation)
            XCTAssertEqual(job.state, .running)
            XCTAssertLessThan(job.progressFraction(), 1)
        }
        retained.installHandoff = CodeInstallHandoff()
        XCTAssertFalse(retained.monitoring().shouldMonitorInBackground)
        XCTAssertEqual(retained.monitoring().installHandoff, retained.installHandoff)
        retained.state = .succeeded
        XCTAssertEqual(retained.monitoring().progressFraction(), 1)
    }
    func testHostPayloadDecodesDirectAndRetainedProgressAndLogs() throws {
        var job = CodeJob(id: "direct", title: "Build"); job.log = "Compile File.swift"
        XCTAssertEqual(try CodeJob.targetStatus(JSONEncoder().encode(job)), job)
        let target = CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: CodeProject(path: "/tmp/App.xcodeproj", scheme: "App"), branch: "main", generation: "test")
        var retained = CodeOvernightJob(requestID: "r", invocationID: "i", target: target); retained.state = .building
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(retained)) as! [String: Any]
        object["compilation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)); object["log"] = job.log
        let decoded = try CodeJob.targetStatus(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.id, retained.id); XCTAssertEqual(decoded.log, job.log)
        XCTAssertEqual(decoded.state, .running)
    }
}
