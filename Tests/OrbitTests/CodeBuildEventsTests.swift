import XCTest
@testable import OrbitCore
@testable import OrbitMac

final class CodeBuildEventsTests: XCTestCase {
    private func value(_ text: String) -> [String: String] { ["_value": text] }
    private func event(_ name: String, index: Int = 1, extra: [String: Any] = [:]) throws -> Data {
        var payload: [String: Any] = ["sectionIndex": value(String(index))]; payload.merge(extra) { _, new in new }
        var data = try JSONSerialization.data(withJSONObject: ["name": value(name), "structuredPayload": payload])
        data.append(10); return data
    }
    private func start(_ index: Int, title: String = "Compile Feature.swift", command: Bool = true) throws -> Data {
        try event("logSectionCreated", index: index, extra: ["head": ["_type": ["_name": command ? "ActivityLogCommandInvocationSectionHead" : "ActivityLogSectionHead"], "title": value(title)]])
    }
    func testCountsRealCommandsAndIgnoresContainersOutputAndDuplicates() throws {
        var parser = CodeBuildEventParser()
        parser.append(try start(1, command: false)); parser.append(try start(2)); parser.append(try start(2))
        parser.append(try event("logTextAppended", index: 2)); parser.append(try event("logSectionClosed", index: 1))
        XCTAssertEqual(parser.snapshot.active, 1); XCTAssertEqual(parser.snapshot.completed, 0)
        XCTAssertEqual(parser.snapshot.operation, "Compile Feature.swift")
        parser.append(try event("logSectionClosed", index: 2)); parser.append(try event("logSectionClosed", index: 2))
        XCTAssertEqual(parser.snapshot.active, 0); XCTAssertEqual(parser.snapshot.completed, 1)
        let initial = CodeBuildEventSnapshot().fraction(expectedTasks: nil)
        XCTAssertGreaterThan(parser.snapshot.fraction(expectedTasks: nil), initial)
        XCTAssertLessThan(parser.snapshot.fraction(expectedTasks: 1), 1)
    }
    func testArbitraryByteFragmentsAndMalformedOrOversizedLinesRecover() throws {
        var parser = CodeBuildEventParser()
        for byte in try start(5, title: "Compile café.swift") { parser.append(Data([byte])) }
        XCTAssertEqual(parser.snapshot.operation, "Compile café.swift")
        parser.append(Data("invalid json\n".utf8))
        parser.append(Data(repeating: 65, count: 1024 * 1024 + 1)); parser.append(Data("\n".utf8))
        parser.append(try event("logSectionClosed", index: 5))
        XCTAssertEqual(parser.snapshot.completed, 1)
    }
    func testActionsCanReuseSectionIDsAndOnlyConfirmedSuccessFinishesBuild() throws {
        var parser = CodeBuildEventParser()
        for _ in 0..<2 {
            parser.append(try event("actionStarted")); parser.append(try start(1)); parser.append(try event("logSectionClosed", index: 1))
        }
        XCTAssertEqual(parser.snapshot.completed, 2)
        parser.append(try event("actionFinished", extra: ["tail": ["buildResult": ["status": value("failed")]]]))
        XCTAssertFalse(parser.snapshot.buildSucceeded)
        parser.append(try event("actionFinished", extra: ["tail": ["buildResult": ["status": value("succeeded")]]]))
        XCTAssertTrue(parser.snapshot.buildSucceeded); XCTAssertEqual(parser.snapshot.fraction(expectedTasks: 200), 1)
    }
    func testEventProgressDoesNotMoveWhenOnlyTimePasses() {
        var progress = CodeJobProgress(stage: "Compile Feature.swift", start: 0.25, end: 0.8, estimatedSeconds: 1, reportedFraction: 0.4)
        progress.completedTasks = 42
        XCTAssertEqual(progress.fraction(), progress.fraction(at: Date().addingTimeInterval(500)))
        var job = CodeJob(id: "job", title: "Build"); job.progress = progress
        XCTAssertEqual(job.progressDetail, "42 build tasks completed")
        XCTAssertEqual(job.estimatingProgress().progress?.reportedFraction, 0.4)
    }
}
