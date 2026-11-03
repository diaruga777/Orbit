import XCTest
import OrbitCore
@testable import OrbitHost

final class CodeClientRPCTests: XCTestCase {
    func testPhoneBridgeCarriesSelfUpdateAcknowledgementThroughRealHostAndPersistsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try CodeOvernightStore(root: root.appendingPathComponent("Builds/Overnight"))
        let target = CodeOvernightTarget(peerID: "orbit-mac", deviceID: "fixture-phone",
            project: CodeProject(path: "/Fixture/App.xcodeproj", scheme: "App"), branch: "main", generation: "fixture")
        var job = CodeOvernightJob(requestID: "fixture", invocationID: "fixture", target: target)
        job.state = .waitingForPhone
        job.installHandoff = CodeInstallHandoff(token: "fixture-handoff")
        try journal.save(job)
        let host = try OrbitHost(root: root)
        await host.openPairing(); try await host.trust("fixture-phone")
        let jobID = job.id
        let client = CodeClient.overRPC { params in
            XCTAssertEqual(params["operation"] as? String, "acknowledgeInstall")
            XCTAssertEqual(params["jobID"] as? String, jobID)
            XCTAssertNotNil(params["handoffToken"] as? String)
            let frame = try JSONSerialization.data(withJSONObject: ["method": "code", "params": params])
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: await host.handle(frame, peer: "fixture-phone")) as? [String: Any])
            XCTAssertNil(response["error"])
            return try XCTUnwrap(response["result"])
        }
        var request = CodeRequest(.acknowledgeInstall)
        request.jobID = job.id; request.handoffToken = job.installHandoff?.token
        let response = try await client.call(request)
        XCTAssertEqual(response.job?.installHandoff?.acknowledged, true)
        XCTAssertEqual(response.job?.state, .running, "Acknowledgement alone does not confirm installation")
        let saved = try CodeOvernightStore(root: root.appendingPathComponent("Builds/Overnight")).jobs()
        XCTAssertEqual(saved.first?.installHandoff?.acknowledged, true)
        let repeated = try await client.call(request)
        XCTAssertEqual(repeated.job?.installHandoff, response.job?.installHandoff)
        request.id = UUID().uuidString; request.handoffToken = "wrong"
        do { _ = try await client.call(request); XCTFail("Wrong token must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer ready")) }
    }
    func testPhoneBridgePreservesStructuredEditorRequestsAndReplies() async throws {
        let project = CodeProject(path: "/Fixture/Hello World.xcodeproj", scheme: "Hello")
        var request = CodeRequest(.save, path: "/Fixture/Hello.swift")
        request.project = project; request.text = "let greeting = \"Hello 🌍\"\n"; request.version = "fixture-version"
        let expected = request
        let client = CodeClient.overRPC { params in
            let decoded = try JSONDecoder().decode(CodeRequest.self, from: JSONSerialization.data(withJSONObject: params))
            XCTAssertEqual(decoded.id, expected.id)
            XCTAssertEqual(decoded.path, expected.path)
            XCTAssertEqual(decoded.project, expected.project)
            XCTAssertEqual(decoded.text, expected.text)
            XCTAssertEqual(decoded.version, expected.version)
            var response = CodeResponse(); response.conflict = true; response.schemes = ["Hello", "Widget"]
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(response))
        }
        let response = try await client.call(request)
        XCTAssertTrue(response.conflict)
        XCTAssertEqual(response.schemes, ["Hello", "Widget"])
    }
    func testPhoneBridgePreservesTransportAndServiceFailures() async throws {
        let offline = CodeClient.overRPC { _ in throw CodeFailure("Fixture Mac unavailable") }
        do { _ = try await offline.call(CodeRequest(.overnightStatus)); XCTFail("Transport failure must propagate") }
        catch { XCTAssertEqual(error.localizedDescription, "Fixture Mac unavailable") }
        let rejected = CodeClient.overRPC { _ in
            var response = CodeResponse(); response.error = "Fixture request rejected"
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(response))
        }
        do { _ = try await rejected.call(CodeRequest(.overnightStatus)); XCTFail("Service failure must propagate") }
        catch { XCTAssertEqual(error.localizedDescription, "Fixture request rejected") }
    }
}
