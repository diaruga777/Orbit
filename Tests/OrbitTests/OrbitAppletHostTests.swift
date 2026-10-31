import XCTest
import AppKit
import OrbitWidgets
@testable import OrbitHost

final class OrbitAppletHostTests: XCTestCase {
    private func call(_ host: OrbitHost, _ method: String, _ params: [String: Any] = [:], peer: String? = nil) async throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        return try JSONSerialization.jsonObject(with: await host.handle(request, peer: peer)) as? [String: Any] ?? [:]
    }
    func testDeliveryIsInertLocalOnlyAndRemovalPreservesIndependentPhoneCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrbitHost(root: root)
        await host.openPairing(); try await host.trust("phone")
        let file = root.appendingPathComponent("untrusted.js")
        try Data((OrbitAppletExport.blank + "\nthrow new Error('must not execute');").utf8).write(to: file)
        let denied = try await call(host, "applet_add", ["path": file.path], peer: "phone")
        XCTAssertNotNil(denied["error"])
        let added = try await call(host, "applet_add", ["path": file.path])
        XCTAssertEqual((added["result"] as? [String: Any])?["pendingPhoneApproval"] as? Bool, true)
        let listed = try await call(host, "applets", peer: "phone")
        let scripts = try XCTUnwrap(listed["result"] as? [[String: String]])
        XCTAssertEqual(scripts.count, 1)
        let phone = OrbitWidgetStore(directory: root.appendingPathComponent("phone"), applets: true)
        try phone.install(try XCTUnwrap(scripts[0]["source"]))
        let traversal = try await call(host, "applet_remove", ["id": "../untrusted"])
        XCTAssertNotNil(traversal["error"])
        _ = try await call(host, "applet_remove", ["id": "my-applet"])
        XCTAssertNotNil(try phone.script("my-applet"))
        let exportDenied = try await call(host, "applet_export", ["destination": root.appendingPathComponent("bad").path, "bundleID": "org.example.bad"], peer: "phone")
        XCTAssertNotNil(exportDenied["error"])
    }
    func testStandaloneExportIsCommittedSelfContainedAndHasIcon() async throws {
        let destination = ProcessInfo.processInfo.environment["ORBIT_TEST_APPLET_EXPORT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if ProcessInfo.processInfo.environment["ORBIT_TEST_APPLET_EXPORT"] == nil { try? FileManager.default.removeItem(at: destination) } }
        let result = try await OrbitAppletExport.create(source: nil, destination: destination, bundleID: "org.example.orbit.testapplet")
        XCTAssertEqual(result["scheme"], "AppletHost")
        for name in ["Sources/Diagnostics/OrbitDiagnostics.swift", "Sources/Diagnostics/OrbitAppDiagnostics.swift", "Sources/Runtime/OrbitAppletDiagnostics.swift", "Sources/Runtime/OrbitWidgetRuntime.swift", "Sources/Runtime/OrbitAppletPolling.swift", "Sources/UI/OrbitAppletBackground.swift", "Sources/UI/OrbitAppletView.swift", "Sources/HostApp.swift", "Applet.js", "AppletHost.xcodeproj/project.pbxproj", ".git/HEAD", "Assets.xcassets/AppIcon.appiconset/Icon.png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path), name)
        }
        let config = try String(contentsOf: destination.appendingPathComponent("Config/App.xcconfig"), encoding: .utf8)
        XCTAssertFalse(config.contains("DEVELOPMENT_TEAM")); XCTAssertFalse(config.contains("ENTITLEMENTS"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["fetch"])
        XCTAssertEqual(info["BGTaskSchedulerPermittedIdentifiers"] as? [String], ["org.example.orbit.testapplet.applet-poll"])
        let icon = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/Icon.png"))))
        XCTAssertEqual(icon.pixelsWide, 1024); XCTAssertFalse(icon.hasAlpha)
        do { _ = try await OrbitAppletExport.create(source: nil, destination: destination, bundleID: "org.example.bad"); XCTFail("Overwrote existing project") } catch { }
    }
}
