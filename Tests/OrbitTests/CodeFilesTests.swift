import XCTest
@testable import OrbitCore
@testable import OrbitMac

final class CodeFilesTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testExplicitSavePreservesCRLFAndDetectsMacConflict() throws {
        let url = directory.appendingPathComponent("Test.swift")
        try Data("let value = 1\r\n".utf8).write(to: url)
        let files = CodeFiles(); let original = try files.open(url.path)
        try Data("let value = 2\r\n".utf8).write(to: url)
        let conflict = try files.save(path: url.path, text: "let value = 3\r\n", expected: original.version)
        XCTAssertTrue(conflict.1); XCTAssertEqual(conflict.0.text, "let value = 2\r\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let value = 2\r\n")
        let saved = try files.save(path: url.path, text: "let value = 3\r\n", expected: conflict.0.version)
        XCTAssertFalse(saved.1); XCTAssertEqual(try Data(contentsOf: url), Data("let value = 3\r\n".utf8))
    }
    func testUTF16BOMAndPermissionsSurviveSave() throws {
        let url = directory.appendingPathComponent("Text.swift")
        try (Data([0xFF, 0xFE]) + "let emoji = \"🌙\"\r\n".data(using: .utf16LittleEndian)!).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let files = CodeFiles(); let original = try files.open(url.path)
        XCTAssertEqual(original.encoding, "utf16le")
        let result = try files.save(path: url.path, text: original.text + "// edit\r\n", expected: original.version)
        XCTAssertFalse(result.1); XCTAssertTrue(try Data(contentsOf: url).starts(with: [0xFF, 0xFE]))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o640)
    }
    func testBinaryOversizedAndSymlinkFilesRejected() throws {
        let files = CodeFiles(); let url = directory.appendingPathComponent("source")
        try Data([0, 1, 2]).write(to: url); XCTAssertThrowsError(try files.open(url.path))
        try Data(repeating: 65, count: CodeWire.maxFileBytes + 1).write(to: url); XCTAssertThrowsError(try files.open(url.path))
        try Data("source".utf8).write(to: url)
        let link = directory.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try files.open(link.path)); XCTAssertThrowsError(try files.save(path: link.path, text: "overwrite", expected: "anything"))
        XCTAssertThrowsError(try files.open(directory.path))
    }
    func testDraftsAreIsolatedByPeerAndPersistUnsavedText() throws {
        let store = try CodeDraftStore(root: directory)
        let original = CodeDocument(path: "/same/file.swift", text: "base", version: "v1")
        try store.save(CodeDraft(base: original, text: "edited", selection: 3), peer: "macA")
        XCTAssertNil(try store.load(peer: "macB", path: original.path))
        let restored = try XCTUnwrap(store.load(peer: "macA", path: original.path))
        XCTAssertTrue(restored.modified); XCTAssertEqual(restored.base.version, "v1"); XCTAssertEqual(restored.text, "edited")
    }
    func testUTF16LSPPositionsRoundTrip() {
        let text = "let moon = \"🌙\"\r\nlet next = 2"
        let offset = ("let moon = \"🌙\"\r\nlet " as NSString).length
        let position = CodePosition.at(utf16Offset: offset, in: text)
        XCTAssertEqual(position, CodePosition(line: 1, character: 4)); XCTAssertEqual(position.offset(in: text), offset)
        XCTAssertNil(CodePosition(line: 99, character: 0).offset(in: text))
    }
    func testServiceSaveRetryAndRequestIDMisuse() async throws {
        let file = directory.appendingPathComponent("file.swift"); try Data("one".utf8).write(to: file)
        let service = try CodeService(root: directory.appendingPathComponent("service"))
        let client = CodeClient { await service.handle($0) }
        let opened = try await client.call(CodeRequest(.open, path: file.path))
        var request = CodeRequest(.save, path: file.path); request.text = "two"; request.version = opened.document!.version
        let first = try await client.call(request); let again = try await client.call(request)
        XCTAssertEqual(first.document, again.document)
        let restarted = try CodeService(root: directory.appendingPathComponent("restarted"))
        let retry = try await CodeClient { await restarted.handle($0) }.call(request)
        XCTAssertFalse(retry.conflict)
        request.text = "three"
        do { _ = try await client.call(request); XCTFail("Reused ID must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("reused")) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two")
    }
    func testCancellingCommandStopsItsChildren() async throws {
        let process = CodeProcess()
        let marker = directory.appendingPathComponent("child-survived")
        let ready = directory.appendingPathComponent("ready")
        let child = "import time,pathlib; time.sleep(1); pathlib.Path(\"" + marker.path + "\").touch()"
        let parent = "import subprocess,sys,time,pathlib; subprocess.Popen([sys.executable,'-c',sys.argv[1]]); pathlib.Path(sys.argv[2]).touch(); time.sleep(30)"
        let task = Task { try await process.run("/usr/bin/python3", ["-c", parent, child, ready.path], directory: directory.path, log: directory.appendingPathComponent("process.log")) }
        for _ in 0..<50 { if FileManager.default.fileExists(atPath: ready.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        process.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testInvalidDeploymentCannotLaunchAProcess() async throws {
        let jobs = try CodeJobs(root: directory)
        var request = CodeRequest(.deploy); request.project = CodeProject(path: "/does/not/exist.xcodeproj", scheme: "Fake")
        do { _ = try await jobs.start(request); XCTFail("Missing project must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("Select")) }
    }
}
