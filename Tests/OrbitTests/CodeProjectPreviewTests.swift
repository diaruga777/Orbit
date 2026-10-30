import XCTest
@testable import OrbitMac
@testable import OrbitCore

final class CodeProjectPreviewTests: XCTestCase {
    func testInertPreviewFiltersDependenciesExtensionsTestsAndMacAppsAndUpdatesAfterEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("App.xcodeproj")
        let folder = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/feature/reader\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        var objects: [String: [String: Any]] = [:]
        for (name, type, sdk) in [("Reader", "application", "iphoneos"), ("ReaderUI", "framework", "iphoneos"), ("Tests", "bundle.unit-test", "iphoneos"), ("Widget", "app-extension", "iphoneos"), ("Desktop", "application", "macosx")] {
            objects[name] = ["isa": "PBXNativeTarget", "name": name, "productType": "com.apple.product-type." + type, "buildConfigurationList": name + "List"]
            objects[name + "List"] = ["buildConfigurations": [name + "Debug"]]
            objects[name + "Debug"] = ["name": "Debug", "buildSettings": ["SDKROOT": sdk, "PRODUCT_BUNDLE_IDENTIFIER": "example." + name]]
        }
        func save() throws {
            try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0).write(to: project.appendingPathComponent("project.pbxproj"))
        }
        try save()
        try Data(#"<Scheme><LaunchAction><BuildableProductRunnable><BuildableReference BlueprintName="Reader"/></BuildableProductRunnable></LaunchAction></Scheme>"#.utf8).write(to: folder.appendingPathComponent("Reading.xcscheme"))
        // A scheme named like an app, but explicitly without a Run action, is excluded.
        try Data("<Scheme><TestAction/></Scheme>".utf8).write(to: folder.appendingPathComponent("Reader.xcscheme"))
        let rows = CodeProjectPreview.apps(path: project.path)
        XCTAssertEqual(rows.map(\.project.scheme), ["Reading"])
        XCTAssertEqual(rows.first?.branch, "feature/reader")
        XCTAssertEqual(rows.first?.name, "Reader")
        XCTAssertNil(rows.first?.iconPNG)
        let automatic = CodeProject(path: project.path, scheme: "ReaderUI")
        let appSettings = ["TARGET_NAME": "Reader", "PRODUCT_TYPE": "com.apple.product-type.application", "SUPPORTED_PLATFORMS": "iphoneos"]
        XCTAssertNil(try CodeDeviceSupport.primarySettings([appSettings], project: automatic), "A library scheme cannot borrow its app dependency")
        objects["Reader"]?["productType"] = "com.apple.product-type.framework"
        try save()
        XCTAssertTrue(CodeProjectPreview.apps(path: project.path).isEmpty)
        // No Xcode project process, package resolution, script, build or device is needed.
    }

    func testAppPickerPrefersCanonicalSchemeAndKeepsAliasesAvailableForAdvanced() {
        let app = CodeBuildApp(project: CodeProject(path: "/Apps.xcodeproj", scheme: "Music"), name: "Music", bundleID: "example.music")
        var uiTests = app; uiTests.project.scheme = "MusicUI"
        var custom = app; custom.name = "Reader"; custom.bundleID = "example.reader"; custom.project.scheme = "Read Debug"
        let choices = CodeBuildApp.registrationChoices([uiTests, custom, app])
        XCTAssertEqual(choices.map(\.project.scheme), ["Music", "Read Debug"])
        XCTAssertEqual(uiTests.registrationIdentity, app.registrationIdentity)
        XCTAssertNotEqual(custom.registrationIdentity, app.registrationIdentity)
        XCTAssertEqual(CodeBuildApp.registrationChoices([uiTests]).first?.project.scheme, "MusicUI", "An alias-only app must remain available")
    }

    func testWorkspaceResolvesNestedProjectReferencesAndInvalidMetadataIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Apps.xcworkspace")
        let project = root.appendingPathComponent("Nested/Reader.xcodeproj")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let objects: [String: Any] = ["app": ["isa": "PBXNativeTarget", "name": "Reader", "productType": "com.apple.product-type.application", "buildConfigurationList": "list"], "list": ["buildConfigurations": ["debug"]], "debug": ["name": "Debug", "buildSettings": ["SDKROOT": "iphoneos"]]]
        try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0).write(to: project.appendingPathComponent("project.pbxproj"))
        try Data(#"<Workspace><Group location="group:Nested"><FileRef location="group:Reader.xcodeproj"/></Group></Workspace>"#.utf8).write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
        let rows = CodeProjectPreview.apps(path: workspace.path)
        XCTAssertEqual(rows.map(\.project.scheme), ["Reader"])
        XCTAssertEqual(rows.first?.project.path, workspace.path)
        let schemes = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        try Data(#"<Scheme><LaunchAction><BuildableProductRunnable><BuildableReference BlueprintName="Reader"/></BuildableProductRunnable></LaunchAction></Scheme>"#.utf8).write(to: schemes.appendingPathComponent("Reading.xcscheme"))
        XCTAssertEqual(CodeProjectPreview.apps(path: workspace.path).map(\.project.scheme), ["Reader", "Reading"])
        XCTAssertEqual(try CodeDeviceSupport.runnableTarget(path: workspace.path, scheme: "Reading"), "Reader")
        try Data("broken".utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        XCTAssertTrue(CodeProjectPreview.apps(path: workspace.path).isEmpty)
    }
}
