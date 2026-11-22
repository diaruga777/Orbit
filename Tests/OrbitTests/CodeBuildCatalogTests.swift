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
        reader.launchAfterInstall = true
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
        XCTAssertEqual(row?.launchAfterInstall, true)
        XCTAssertEqual(restored.apps(peer: "mac").count, 3)
        XCTAssertTrue(restored.apps(peer: "anotherMac").isEmpty)
        XCTAssertNil(restored.defaultDevice(peer: "anotherMac"))
    }
    func testSchemesWithSameBundleRemainSeparateAndKeepTheirOwnSettings() {
        let catalog = CodeBuildCatalog(defaults: defaults)
        var first = CodeBuildApp(project: CodeProject(path: "/App.xcodeproj", scheme: "App"), name: "App", bundleID: "app", branch: "feature", deviceID: "phone")
        first.jobID = "job"
        first.launchAfterInstall = true
        let alias = CodeBuildApp(project: CodeProject(path: first.project.path, scheme: "App Release"), name: "App", bundleID: "app")
        catalog.save([first], peer: "mac")
        catalog.merge([CodeBuildApp(project: first.project, name: "App", bundleID: "app"), alias], path: first.project.path, peer: "mac")
        let rows = catalog.apps(peer: "mac")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.key == first.key }?.jobID, "job")
        XCTAssertEqual(rows.first { $0.key == alias.key }?.branch, "main")
        XCTAssertNil(rows.first { $0.key == alias.key }?.deviceID)
        XCTAssertNil(rows.first { $0.key == alias.key }?.jobID)
        XCTAssertEqual(rows.first { $0.key == first.key }?.launchAfterInstall, true)
        XCTAssertNil(rows.first { $0.key == alias.key }?.launchAfterInstall)
    }
    func testOlderBuildRowsDefaultToInstallOnlyAndExplicitOptOutSurvivesDiscovery() throws {
        let legacy = Data(#"{"project":{"path":"/App.xcodeproj","scheme":"App","appID":"","groupID":""},"name":"App","bundleID":"app","branch":"main"}"#.utf8)
        let app = try JSONDecoder().decode(CodeBuildApp.self, from: legacy)
        XCTAssertNil(app.launchAfterInstall)
        let catalog = CodeBuildCatalog(defaults: defaults)
        catalog.save([app], peer: "mac")
        catalog.edit(key: app.key, peer: "mac") { $0.launchAfterInstall = false }
        var discovered = app; discovered.launchAfterInstall = true
        catalog.merge([discovered], path: app.project.path, peer: "mac")
        XCTAssertEqual(catalog.apps(peer: "mac").first?.launchAfterInstall, false)
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
    func testDeviceBuildUsesPlainProjectFolderAndPreservesItsFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Source")
        let projectURL = folder.appendingPathComponent("Example.xcworkspace")
        let state = root.appendingPathComponent("State")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let localFile = folder.appendingPathComponent("Local.xcconfig")
        try Data("local settings".utf8).write(to: localFile)
        let project = CodeProject(path: projectURL.path, scheme: "Example")

        let checkout = try await CodeDeviceCheckout.create(project: project, branch: "main", root: state, name: "plain")
        XCTAssertEqual(checkout.directory.path, folder.path)
        XCTAssertEqual(checkout.project, project)
        XCTAssertNil(checkout.revision)
        XCTAssertNil(checkout.includesLocalChanges)
        await checkout.remove(root: state)
        XCTAssertEqual(try String(contentsOf: localFile, encoding: .utf8), "local settings")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: state.path), [])
        XCTAssertFalse(CodeDeviceCheckout.usesProjectFolder(project: project, branch: "refs/remotes/origin/main"))

        // A broken Git worktree marker still makes this a Git build.
        try Data("gitdir: missing".utf8).write(to: root.appendingPathComponent(".git"))
        do {
            _ = try await CodeDeviceCheckout.create(project: project, branch: "main", root: state, name: "broken")
            XCTFail("Broken Git metadata must not fall back to the working files")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Git:"))
        }
    }

    func testLocalCheckoutIncludesWorkingFilesAndPreservesEditorBranchAndIndex() async throws {
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
        let binary = repository.appendingPathComponent("Binary")
        try Data([0, 1, 2]).write(to: binary)
        let deleted = repository.appendingPathComponent("Deleted.swift")
        try Data("delete this".utf8).write(to: deleted)
        try Data("Local.xcconfig\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "main"])
        let revision = try await git(["rev-parse", "HEAD"])
        _ = try await git(["checkout", "-b", "editor"])
        try Data("editor-only commit".utf8).write(to: repository.appendingPathComponent("Editor.swift"))
        _ = try await git(["add", "Editor.swift"])
        _ = try await git(["commit", "-m", "Add file on editor branch"])
        let editorRevision = try await git(["rev-parse", "HEAD"])
        try Data("ignored settings".utf8).write(to: repository.appendingPathComponent("Local.xcconfig"))
        let project = CodeProject(path: projectPath.path, scheme: "App")
        let clean = try await CodeDeviceCheckout.create(project: project, branch: "main", root: state, name: "clean")
        XCTAssertEqual(clean.includesLocalChanges, false)
        await clean.remove(root: state)

        try Data("new source".utf8).write(to: repository.appendingPathComponent("Extra source.swift"))

        try Data("staged Mac edits".utf8).write(to: source)
        _ = try await git(["add", "Source.swift"])
        try Data("unstaged Mac edits".utf8).write(to: source)
        try Data([0, 8, 9]).write(to: binary)
        try FileManager.default.removeItem(at: deleted)
        let originalStatus = try await git(["--no-optional-locks", "status", "--porcelain"])
        let index = repository.appendingPathComponent(".git/index")
        let originalIndex = try Data(contentsOf: index)
        let checkout = try await CodeDeviceCheckout.create(project: project, branch: "main", root: state, name: UUID().uuidString)
        XCTAssertEqual(checkout.revision, revision)
        XCTAssertEqual(checkout.includesLocalChanges, true)
        XCTAssertEqual(try Data(contentsOf: index), originalIndex)
        XCTAssertEqual(try String(contentsOf: checkout.directory.appendingPathComponent("Source.swift"), encoding: .utf8), "unstaged Mac edits")
        XCTAssertEqual(try String(contentsOf: checkout.directory.appendingPathComponent("Extra source.swift"), encoding: .utf8), "new source")
        XCTAssertEqual(try Data(contentsOf: checkout.directory.appendingPathComponent("Binary")), Data([0, 8, 9]))
        for name in ["Local.xcconfig", "Editor.swift", "Deleted.swift"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.directory.appendingPathComponent(name).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.project.path))
        let branch = try await git(["branch", "--show-current"])
        XCTAssertEqual(branch, "editor")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "unstaged Mac edits")
        let head = try await git(["rev-parse", "HEAD"])
        XCTAssertEqual(head, editorRevision)
        let status = try await git(["--no-optional-locks", "status", "--porcelain"])
        XCTAssertEqual(status, originalStatus)
        await checkout.remove(root: state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.directory.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: state.path).contains { $0.hasPrefix("LocalSource-") })

        _ = try await git(["worktree", "add", "-b", "conflicting", state.appendingPathComponent("ConflictSource").path, revision])
        let conflictSource = state.appendingPathComponent("ConflictSource")
        try Data("branch changed this too".utf8).write(to: conflictSource.appendingPathComponent("Source.swift"))
        _ = try await CodeDeviceSupport.git(["commit", "-am", "Conflicting source"], directory: conflictSource.path, root: state)
        do {
            _ = try await CodeDeviceCheckout.create(project: project, branch: "conflicting", root: state, name: "conflict")
            XCTFail("Conflicting local changes must stop the build")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Local changes don’t apply"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("Checkout-conflict").path))
        XCTAssertEqual(try Data(contentsOf: index), originalIndex)
        do {
            _ = try await CodeDeviceCheckout.create(project: CodeProject(path: projectPath.path, scheme: "App"), branch: "--help", root: state, name: UUID().uuidString)
            XCTFail("Option-shaped refs must not become git options")
        } catch {}
    }

    func testDetachedCheckoutPreparesIgnoredPackageFromCommittedHook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = root.appendingPathComponent("Repo")
        let state = root.appendingPathComponent("State")
        let project = repo.appendingPathComponent("App.xcodeproj")
        let hooks = repo.appendingPathComponent(".orbit")
        let hook = hooks.appendingPathComponent("prepare-build")
        let recipe = repo.appendingPathComponent("PackageRecipe")
        let files = FileManager.default
        defer { try? files.removeItem(at: root) }
        for folder in [project, hooks, state] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        func git(_ args: [String]) async throws -> String {
            try await CodeDeviceSupport.git(args, directory: repo.path, root: state)
        }
        _ = try await git(["init", "-b", "main"])
        _ = try await git(["config", "user.name", "Orbit Tests"])
        _ = try await git(["config", "user.email", "orbit@example.invalid"])
        try Data("project".utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        try Data("Modules/Vendor/".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        try Data("committed recipe".utf8).write(to: recipe)
        try Data("""
        #!/bin/sh
        set -eu
        mkdir -p Modules/Vendor/Local
        cp PackageRecipe Modules/Vendor/Local/Package.swift
        echo 'Prepared the local package'
        """.utf8).write(to: hook)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try await git(["add", "."])
        _ = try await git(["commit", "-m", "Prepare a generated package"])
        _ = try await git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try await git(["checkout", "-b", "editor"])
        try Data("dirty recipe".utf8).write(to: recipe)
        try Data("#!/bin/sh\necho 'Hook diagnostic' >&2\nexit 1\n".utf8).write(to: hook)
        _ = try await git(["add", ".orbit/prepare-build"])
        _ = try await git(["commit", "-m", "Fail preparation on editor branch"])

        let source = CodeProject(path: project.path, scheme: "App")
        let checkout = try await CodeDeviceCheckout.create(project: source, branch: "main", root: state, name: "prepared")
        let relativePath = "Modules/Vendor/Local/Package.swift"
        XCTAssertEqual(try String(contentsOf: checkout.directory.appendingPathComponent(relativePath), encoding: .utf8), "dirty recipe")
        XCTAssertEqual(checkout.includesLocalChanges, true)
        XCTAssertFalse(files.fileExists(atPath: repo.appendingPathComponent(relativePath).path))
        XCTAssertTrue(try String(contentsOf: state.appendingPathComponent("prepared.log"), encoding: .utf8).contains("Prepared the local package"))
        await checkout.remove(root: state)

        let fetched = try await CodeDeviceCheckout.create(project: source, branch: "refs/remotes/origin/main", root: state, name: "remote")
        XCTAssertEqual(try String(contentsOf: fetched.directory.appendingPathComponent(relativePath), encoding: .utf8), "committed recipe")
        XCTAssertEqual(fetched.includesLocalChanges, false)
        await fetched.remove(root: state)

        do {
            _ = try await CodeDeviceCheckout.create(project: source, branch: "editor", root: state, name: "failed")
            XCTFail("A failed hook must stop before Xcode runs")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Project setup failed"))
            XCTAssertFalse(error.localizedDescription.contains("Hook diagnostic"))
        }
        XCTAssertFalse(files.fileExists(atPath: state.appendingPathComponent("Checkout-failed").path))
        XCTAssertTrue(try String(contentsOf: state.appendingPathComponent("failed.log"), encoding: .utf8).contains("Hook diagnostic"))
    }

    func testXcodePackageFailureKeepsPathInConsole() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let console = root.appendingPathComponent("job.log")
        let path = "/private/Checkout/Modules/Vendor/Local"
        let diagnostic = """
        xcodebuild: error: Could not resolve package dependencies:
          the package at '\(path)' cannot be accessed (\(path) doesn't exist in file system)
        """
        do {
            _ = try await CodeDeviceSupport.json("/bin/sh", ["-c", "printf '%s\n' \"$1\" >&2; exit 74", "fixture", diagnostic],
                                                 directory: root.path, root: root, diagnosticLog: console)
            XCTFail("A missing package must fail the Xcode query")
        } catch {
            XCTAssertEqual(error.localizedDescription, "A local Swift package is missing. Check the build console for details.")
        }
        XCTAssertTrue(try String(contentsOf: console, encoding: .utf8).contains(diagnostic))
        XCTAssertEqual(CodeBuildFailure.message(output: diagnostic), "A local Swift package is missing. Check the build console for details.")
    }

    func testXcodeJSONIgnoresWarningBracketsAndPackageProgress() throws {
        let output = Data("2026-10-16 [MT] warning: no destinations\nResolved packages: Support\n[{\"buildSettings\":{\"PRODUCT_TYPE\":\"app\"}}]\n".utf8)
        let parsed = try CodeDeviceSupport.parseJSONOutput(output) as? [[String: Any]]
        XCTAssertEqual((parsed?.first?["buildSettings"] as? [String: String])?["PRODUCT_TYPE"], "app")
    }

}
