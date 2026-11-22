import XCTest
import CoreGraphics
import ImageIO
@testable import OrbitCore
@testable import OrbitMac

final class CodeAppIconTests: XCTestCase {
    func testSchemesWithSameIconNameUseTheirOwnTargetAndBuiltPrimaryIcon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectFile = root.appendingPathComponent("Shared.xcodeproj")
        try FileManager.default.createDirectory(at: projectFile, withIntermediateDirectories: true)
        let objects: [String: [String: Any]] = [
            "first": ["isa": "PBXNativeTarget", "name": "First", "buildPhases": ["firstPhase"]],
            "second": ["isa": "PBXNativeTarget", "name": "Second", "buildPhases": ["secondPhase"]],
            "firstPhase": ["isa": "PBXResourcesBuildPhase", "files": ["firstResource"]],
            "secondPhase": ["isa": "PBXResourcesBuildPhase", "files": ["secondResource"]],
            "firstResource": ["fileRef": "firstCatalog"],
            "secondResource": ["fileRef": "secondCatalog"],
            "firstCatalog": ["path": "Assets.xcassets", "sourceTree": "<group>"],
            "secondCatalog": ["path": "Assets.xcassets", "sourceTree": "<group>"],
            "firstGroup": ["path": "First", "children": ["firstCatalog"]],
            "secondGroup": ["path": "Second", "children": ["secondCatalog"]]
        ]
        try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0)
            .write(to: projectFile.appendingPathComponent("project.pbxproj"))
        for (app, red) in [("First", 0.25), ("Second", 0.75)] {
            let set = root.appendingPathComponent(app + "/Assets.xcassets/AppIcon.appiconset")
            try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            try Data(#"{"images":[{"idiom":"universal","platform":"ios","filename":"Icon.png"}]}"#.utf8)
                .write(to: set.appendingPathComponent("Contents.json"))
            try writeImage(set.appendingPathComponent("Icon.png"), side: 96, red: red)
        }
        let schemes = projectFile.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        try Data(#"<Scheme><LaunchAction><BuildableProductRunnable><BuildableReference BlueprintIdentifier="second" BuildableName="Second.app"/></BuildableProductRunnable></LaunchAction></Scheme>"#.utf8)
            .write(to: schemes.appendingPathComponent("Alias.xcscheme"))
        XCTAssertEqual(try CodeDeviceSupport.runnableTarget(path: projectFile.path, scheme: "Alias"), "Second")
        let project = CodeProject(path: root.appendingPathComponent("Workspace.xcworkspace").path, scheme: "Alias")
        var settings = ["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "SRCROOT": root.path,
                        "PROJECT_FILE_PATH": projectFile.path, "TARGET_NAME": "First"]
        let first = try XCTUnwrap(CodeAppIcon.png(settings: settings, project: project))
        settings["TARGET_NAME"] = "Second"
        let second = try XCTUnwrap(CodeAppIcon.png(settings: settings, project: project))
        XCTAssertNotEqual(first, second)
        let secondSet = root.appendingPathComponent("Second/Assets.xcassets/AppIcon.appiconset")
        XCTAssertEqual(second, CodeAppIcon.png(iconSet: secondSet))
        try FileManager.default.removeItem(at: secondSet)
        XCTAssertNil(CodeAppIcon.png(settings: settings, project: project))

        let product = root.appendingPathComponent("Second.app")
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
        try writeImage(product.appendingPathComponent("Primary76x76@2x~ipad.png"), side: 96, red: 0.75)
        try writeImage(product.appendingPathComponent("Primary76x76@1x~ipad.png"), side: 64, red: 0.25)
        try writeImage(product.appendingPathComponent("Alternate@3x.png"), side: 192, red: 0.25)
        let info = ["CFBundleIcons~ipad": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["Primary76x76"]],
                                         "CFBundleAlternateIcons": ["CFBundleIconFiles": ["Alternate"]]]]
        XCTAssertEqual(second, CodeAppIcon.png(builtApp: product, info: info))
        try FileManager.default.removeItem(at: product.appendingPathComponent("Primary76x76@2x~ipad.png"))
        try FileManager.default.removeItem(at: product.appendingPathComponent("Primary76x76@1x~ipad.png"))
        XCTAssertNil(CodeAppIcon.png(builtApp: product, info: info))
    }

    func testDiscoveryUsesConfiguredIconAndThumbnailsDefaultIOSAppearance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let icons = root.appendingPathComponent("Assets.xcassets/Actual.appiconset")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeImage(icons.appendingPathComponent("default.png"), side: 512)
        try writeImage(icons.appendingPathComponent("small.png"), side: 32)
        try Data(#"{"images":[{"idiom":"universal","platform":"ios","size":"1024x1024","filename":"missing-dark.png","appearances":[{"appearance":"luminosity","value":"dark"}]},{"idiom":"mac","size":"1024x1024","filename":"missing-mac.png"},{"idiom":"iphone","size":"32x32","filename":"small.png"},{"idiom":"universal","platform":"ios","size":"512x512","filename":"default.png"}]}"#.utf8).write(to: icons.appendingPathComponent("Contents.json"))
        let project = CodeProject(path: root.appendingPathComponent("App.xcodeproj").path, scheme: "UnrelatedAlias")
        let png = try XCTUnwrap(CodeAppIcon.png(iconSet: icons))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 132); XCTAssertEqual(image.height, 132)
        XCTAssertNil(CodeAppIcon.png(settings: [:], project: project))
        var app = CodeBuildApp(project: project, name: "App", bundleID: "app")
        app.iconPNG = png
        XCTAssertEqual(try JSONDecoder().decode(CodeBuildApp.self, from: JSONEncoder().encode(app)).iconPNG, png)
        app.iconPNG = nil
        XCTAssertNil(try JSONDecoder().decode(CodeBuildApp.self, from: JSONEncoder().encode(app)).iconPNG)
    }

    private func writeImage(_ file: URL, side: Int, red: Double = 0.2) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
