import XCTest
@testable import OrbitCore
@testable import OrbitMac

final class CodeBuildCatalogTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() { suite = UUID().uuidString; defaults = UserDefaults(suiteName: suite)! }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testCacheSurvivesRelaunchAndRefreshPreservesRowSettings() {
        let catalog = CodeBuildCatalog(defaults: defaults)
        var reader = CodeBuildApp(project: CodeProject(path: "/Orbit/Orbit.xcodeproj", scheme: "Reader"), name: "Reader", bundleID: "reader", branch: "feature/reader", deviceID: "phone")
        reader.jobID = "job"
        let code = CodeBuildApp(project: CodeProject(path: "/Orbit/Orbit.xcodeproj", scheme: "Code"), name: "Code", bundleID: "code")
        let other = CodeBuildApp(project: CodeProject(path: "/Other/Other.xcodeproj", scheme: "Other"), name: "Other", bundleID: "other")
        catalog.save([reader, code, other], peer: "mac")
        catalog.selectedTab = 1; catalog.setDefaultDevice("phone", peer: "mac")
        var refreshed = reader; refreshed.name = "Orbit Reader"; refreshed.branch = "main"; refreshed.deviceID = nil; refreshed.jobID = nil
        catalog.merge([refreshed, code], path: reader.project.path, peer: "mac")
        let restored = CodeBuildCatalog(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(restored.selectedTab, 1)
        XCTAssertEqual(restored.defaultDevice(peer: "mac"), "phone")
        let row = restored.apps(peer: "mac").first { $0.bundleID == "reader" }
        XCTAssertEqual(row?.project.scheme, "Reader"); XCTAssertEqual(row?.name, "Orbit Reader"); XCTAssertEqual(row?.branch, "feature/reader")
        XCTAssertEqual(row?.deviceID, "phone"); XCTAssertEqual(row?.jobID, "job")
        XCTAssertEqual(restored.apps(peer: "mac").count, 3)
        XCTAssertTrue(restored.apps(peer: "anotherMac").isEmpty)
        XCTAssertNil(restored.defaultDevice(peer: "anotherMac"))
    }
    func testSchemesWithSameBundleRemainSeparateAndKeepTheirOwnSettings() {
        let catalog = CodeBuildCatalog(defaults: defaults)
        var first = CodeBuildApp(project: CodeProject(path: "/App.xcodeproj", scheme: "App"), name: "App", bundleID: "app", branch: "feature", deviceID: "phone")
        first.jobID = "job"
        let alias = CodeBuildApp(project: CodeProject(path: first.project.path, scheme: "App Release"), name: "App", bundleID: "app")
        catalog.save([first], peer: "mac")
        catalog.merge([CodeBuildApp(project: first.project, name: "App", bundleID: "app"), alias], path: first.project.path, peer: "mac")
        let rows = catalog.apps(peer: "mac")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.key == first.key }?.jobID, "job")
        XCTAssertEqual(rows.first { $0.key == alias.key }?.branch, "main")
        XCTAssertNil(rows.first { $0.key == alias.key }?.deviceID)
        XCTAssertNil(rows.first { $0.key == alias.key }?.jobID)
    }
    func testExplicitSchemeSelectsRunAppInsteadOfFirstDependency() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = CodeProject(path: root.appendingPathComponent("App.xcodeproj").path, scheme: "App")
        let folder = URL(fileURLWithPath: project.path).appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let xml = Data(#"<Scheme><BuildAction><BuildableReference BlueprintName="Library"/></BuildAction><LaunchAction><BuildableProductRunnable><BuildableReference BlueprintName="App"/></BuildableProductRunnable></LaunchAction></Scheme>"#.utf8)
        try xml.write(to: folder.appendingPathComponent("App.xcscheme"))
        let library = ["TARGET_NAME": "Library", "PRODUCT_TYPE": "com.apple.product-type.framework", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"]
        let app = ["TARGET_NAME": "App", "PRODUCT_TYPE": "com.apple.product-type.application", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"]
        XCTAssertEqual(try CodeDeviceSupport.primarySettings([library, app], project: project), app)
        XCTAssertNil(try CodeDeviceSupport.primarySettings([library], project: project))
        try Data(#"<Scheme><BuildAction><BuildableReference BlueprintName="App"/></BuildAction><TestAction/></Scheme>"#.utf8).write(to: folder.appendingPathComponent("App.xcscheme"))
        XCTAssertNil(try CodeDeviceSupport.primarySettings([app], project: project), "A test-only scheme must not surface its app dependency")
        XCTAssertTrue(CodeDeviceSupport.isApp(app))
        XCTAssertFalse(CodeDeviceSupport.isApp(library))
        XCTAssertFalse(CodeDeviceSupport.isApp(["PRODUCT_TYPE": "com.apple.product-type.application", "SUPPORTED_PLATFORMS": "macosx"]))
    }
    func testMultiAppCollectionWithRunnableDependencyIsExcluded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("App.xcodeproj")
        let folder = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let xml = Data(#"<Scheme><BuildAction><BuildActionEntries><BuildActionEntry buildForRunning="YES"><BuildableReference BlueprintName="App" BuildableName="App.app"/></BuildActionEntry><BuildActionEntry buildForRunning="YES"><BuildableReference BlueprintName="Companion" BuildableName="Companion.app"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction><BuildableProductRunnable><BuildableReference BlueprintName="App"/></BuildableProductRunnable></LaunchAction></Scheme>"#.utf8)
        try xml.write(to: folder.appendingPathComponent("AllApps.xcscheme"))
        XCTAssertEqual(try CodeDeviceSupport.runnableTarget(path: project.path, scheme: "AllApps"), "")
        // No pbxproj exists, proving collection schemes are excluded before Xcode.
        let apps = try await CodeDeviceSupport.apps(path: project.path, scheme: "AllApps", root: root)
        XCTAssertTrue(apps.isEmpty)
        let alias = Data(#"<Scheme><BuildAction><BuildActionEntries><BuildActionEntry buildForRunning="YES"><BuildableReference BlueprintName="App" BuildableName="App.app"/></BuildActionEntry><BuildActionEntry buildForRunning="YES"><BuildableReference BlueprintName="Library" BuildableName="Library.framework"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction><BuildableProductRunnable><BuildableReference BlueprintName="App"/></BuildableProductRunnable></LaunchAction></Scheme>"#.utf8)
        XCTAssertEqual(try CodeDeviceSupport.parseRunnableTarget(alias), "App")
    }

    func testPackageSchemeWithoutBuildActionIsExcludedButOtherXcodeErrorsRemainVisible() throws {
        let output = Data("2026-10-16 Writing error result bundle\nxcodebuild: error: Scheme OrbitContentRendering is not currently configured for the build action.\n".utf8)
        let result = try CodeDeviceSupport.queryResult(output, status: 66, nonBuildableScheme: "OrbitContentRendering") as? [[String: Any]]
        XCTAssertEqual(result?.count, 0)
        XCTAssertThrowsError(try CodeDeviceSupport.queryResult(output, status: 66, nonBuildableScheme: "Orbit"))
        XCTAssertThrowsError(try CodeDeviceSupport.queryResult(output, status: 66))
        let packageError = Data("xcodebuild: error: Could not resolve package dependencies.".utf8)
        XCTAssertThrowsError(try CodeDeviceSupport.queryResult(packageError, status: 74, nonBuildableScheme: "Orbit"))
        let valid = Data(#"[{"buildSettings":{"TARGET_NAME":"Orbit"}}]"#.utf8)
        XCTAssertEqual((try CodeDeviceSupport.queryResult(valid, status: 0) as? [[String: Any]])?.count, 1)
    }
    func testExplicitNonRunnableSchemeDoesNotQueryXcode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("App.xcodeproj")
        let folder = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // No pbxproj exists: invoking Xcode here would fail.
        try Data(#"<Scheme><BuildAction/><TestAction/><LaunchAction/></Scheme>"#.utf8).write(to: folder.appendingPathComponent("Tests.xcscheme"))
        let apps = try await CodeDeviceSupport.apps(path: project.path, scheme: "Tests", root: root)
        XCTAssertTrue(apps.isEmpty)
    }

    func testDestinationRequiresAvailablePhysicalIOSRowWithoutError() {
        let output = """
        Available destinations for the App scheme:
          { platform:iOS, arch:arm64, id:phone, name:Phone }
          { platform:iOS Simulator, id:sim, name:Simulator }
          { platform:iOS, id:broken, name:Broken, error:Developer Mode disabled }
        Ineligible destinations for the App scheme:
          { platform:iOS, id:offline, name:Offline }
        """
        XCTAssertTrue(CodeDeviceSupport.destinationIsEligible(output, deviceID: "phone"))
        for id in ["sim", "offline", "broken", "phon", "missing"] {
            XCTAssertFalse(CodeDeviceSupport.destinationIsEligible(output, deviceID: id))
        }
    }
    func testOpeningSeveralProjectsRetainsHistoryWithoutChangingSelectedProject() {
        let session = CodeSessionStore(defaults: defaults)
        let one = CodeProject(path: "/One/App.xcodeproj", scheme: "One")
        let two = CodeProject(path: "/Two/App.xcodeproj", scheme: "Two")
        session.setProject(one, peer: "mac"); session.setProject(two, peer: "mac")
        session.setProject(one, peer: "mac")
        XCTAssertEqual(session.recentProjects(peer: "mac"), [one, two])
        XCTAssertTrue(session.recentProjects(peer: "other").isEmpty)
        CodeBuildCatalog(defaults: defaults).save([CodeBuildApp(project: two, name: "Two", bundleID: "two")], peer: "mac")
        XCTAssertEqual(session.project(peer: "mac"), one)
    }
    func testCurrentPhoneSelectionRequiresUniqueMatchAndNeverReplacesSavedPhone() {
        let current = CodeDevice(id: "current", name: "My Phone")
        let other = CodeDevice(id: "other", name: "Other")
        XCTAssertEqual(CodeBuildCatalog.resolveDevice([other, current], preferred: nil, currentName: "My Phone"), current)
        XCTAssertNil(CodeBuildCatalog.resolveDevice([other, current], preferred: nil, currentName: "iPhone"))
        XCTAssertNil(CodeBuildCatalog.resolveDevice([other], preferred: "current", currentName: "Other"))
        XCTAssertEqual(CodeBuildCatalog.resolveDevice([other], preferred: nil, currentName: "iPhone"), other)
        XCTAssertNil(CodeBuildCatalog.resolveDevice([], preferred: nil, currentName: "iPhone"))
    }
    func testDeviceDiscoveryUsesXcodeAvailabilityForUSBAndWirelessPhones() throws {
        // Both phones are available in Xcode even with no CoreDevice tunnel.
        // Discovery must not require an existing build/debug connection.
        let data = Data("""
        Xcode device discovery warning [MT]
        [
          {"simulator":false,"platform":"com.apple.platform.iphoneos","identifier":"wifi","name":"Wi-Fi Phone","interface":"network","available":true,"ignored":false},
          {"simulator":false,"platform":"com.apple.platform.iphoneos","identifier":"usb","name":"USB Phone","interface":"usb","available":true,"ignored":false},
          {"simulator":false,"platform":"com.apple.platform.iphoneos","identifier":"offline","name":"Old Phone","available":false,"error":{"description":"Phone is not connected"}},
          {"simulator":true,"platform":"com.apple.platform.iphonesimulator","identifier":"sim","name":"Simulator","available":true},
          {"simulator":false,"platform":"com.apple.platform.appletvos","identifier":"tv","name":"TV","available":true},
          {"simulator":false,"platform":"com.apple.platform.iphoneos","identifier":"broken","name":"Broken","available":true,"error":{"description":"Developer Mode disabled"}},
          {"simulator":false,"platform":"com.apple.platform.iphoneos","identifier":"ignored","name":"Ignored","available":true,"ignored":true},
          {"simulator":false,"platform":"com.apple.platform.iphoneos","identifier":"unknown","name":"Unknown"}
        ]
        """.utf8)
        XCTAssertEqual(try CodeDeviceSupport.parseDevices(data), [CodeDevice(id: "usb", name: "USB Phone"), CodeDevice(id: "wifi", name: "Wi-Fi Phone")])
    }
    func testDeviceDiscoveryDistinguishesEmptyListFromInvalidOutput() throws {
        XCTAssertEqual(try CodeDeviceSupport.parseDevices(Data("[]".utf8)), [])
        XCTAssertThrowsError(try CodeDeviceSupport.parseDevices(Data("{}".utf8)))
        XCTAssertThrowsError(try CodeDeviceSupport.parseDevices(Data("Xcode failed".utf8)))
    }
    func testBuildOptionsRoundTripAndOldRequestsStillDecode() throws {
        var request = CodeRequest(.runOnDevice); request.project = CodeProject(path: "/App.xcodeproj", scheme: "App")
        request.deviceBuild = CodeDeviceBuild(deviceID: "phone")
        let decoded = try JSONDecoder().decode(CodeRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.deviceBuild?.branch, "main")
        XCTAssertEqual(decoded.deviceBuild?.deviceID, "phone")
        request = CodeRequest(.build)
        let legacy = try JSONDecoder().decode(CodeRequest.self, from: JSONEncoder().encode(request))
        XCTAssertNil(legacy.deviceBuild)
    }
    func testProcessAppendsCommandsToJobLog() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: log) }
        let process = CodeProcess()
        _ = try await process.run("/bin/echo", ["first"], directory: "/tmp", log: log)
        _ = try await process.run("/bin/echo", ["second"], directory: "/tmp", log: log)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "first\nsecond\n")
    }
    func testMainCheckoutPreservesDirtyEditorBranchAndCleansUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("Repo")
        let state = root.appendingPathComponent("State")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        func git(_ args: [String]) async throws -> String {
            try await CodeDeviceSupport.git(args, directory: repository.path, root: state)
        }
        _ = try await git(["init", "-b", "main"])
        _ = try await git(["config", "user.name", "Orbit Tests"])
        _ = try await git(["config", "user.email", "orbit@example.invalid"])
        let projectPath = repository.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        try Data("main project".utf8).write(to: projectPath.appendingPathComponent("project.pbxproj"))
        let source = repository.appendingPathComponent("Source.swift")
        try Data("main source".utf8).write(to: source)
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "main"])
        _ = try await git(["checkout", "-b", "editor"])
        try Data("unsaved Mac edits".utf8).write(to: source)
        let originalStatus = try await git(["status", "--porcelain"])
        let checkout = try await CodeDeviceCheckout.create(project: CodeProject(path: projectPath.path, scheme: "App"), branch: "main", root: state, name: UUID().uuidString)
        XCTAssertEqual(try String(contentsOf: checkout.directory.appendingPathComponent("Source.swift"), encoding: .utf8), "main source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.project.path))
        let branch = try await git(["branch", "--show-current"])
        XCTAssertEqual(branch, "editor")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "unsaved Mac edits")
        let status = try await git(["status", "--porcelain"])
        XCTAssertEqual(status, originalStatus)
        await checkout.remove(root: state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.directory.path))
        do {
            _ = try await CodeDeviceCheckout.create(project: CodeProject(path: projectPath.path, scheme: "App"), branch: "--help", root: state, name: UUID().uuidString)
            XCTFail("Option-shaped refs must not become git options")
        } catch {}
    }

    func testXcodeJSONIgnoresWarningBracketsAndPackageProgress() throws {
        let output = Data("2026-10-16 [MT] warning: no destinations\nResolved packages: Support\n[{\"buildSettings\":{\"PRODUCT_TYPE\":\"app\"}}]\n".utf8)
        let parsed = try CodeDeviceSupport.parseJSONOutput(output) as? [[String: Any]]
        XCTAssertEqual((parsed?.first?["buildSettings"] as? [String: String])?["PRODUCT_TYPE"], "app")
    }

}
