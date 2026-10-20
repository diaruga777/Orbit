import XCTest
import CoreGraphics
import ImageIO
@testable import OrbitCore
@testable import OrbitMac

final class CodeAppIconTests: XCTestCase {
    func testDiscoveryUsesConfiguredIconAndThumbnailsDefaultIOSAppearance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let icons = root.appendingPathComponent("Assets.xcassets/Actual.appiconset")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func writeImage(_ name: String, side: Int) throws {
            let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let image = try XCTUnwrap(context.makeImage())
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(icons.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try writeImage("default.png", side: 512)
        try writeImage("small.png", side: 32)
        try Data(#"{"images":[{"idiom":"universal","platform":"ios","size":"1024x1024","filename":"missing-dark.png","appearances":[{"appearance":"luminosity","value":"dark"}]},{"idiom":"mac","size":"1024x1024","filename":"missing-mac.png"},{"idiom":"iphone","size":"32x32","filename":"small.png"},{"idiom":"universal","platform":"ios","size":"512x512","filename":"default.png"}]}"#.utf8).write(to: icons.appendingPathComponent("Contents.json"))
        let project = CodeProject(path: root.appendingPathComponent("App.xcodeproj").path, scheme: "UnrelatedAlias")
        let png = try XCTUnwrap(CodeAppIcon.png(settings: ["ASSETCATALOG_COMPILER_APPICON_NAME": "Actual", "SRCROOT": root.path], project: project))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 132); XCTAssertEqual(image.height, 132)
        XCTAssertNil(CodeAppIcon.png(settings: ["ASSETCATALOG_COMPILER_APPICON_NAME": "Missing"], project: project))
        XCTAssertNil(CodeAppIcon.png(settings: [:], project: project))
        var app = CodeBuildApp(project: project, name: "App", bundleID: "app")
        app.iconPNG = png
        XCTAssertEqual(try JSONDecoder().decode(CodeBuildApp.self, from: JSONEncoder().encode(app)).iconPNG, png)
        app.iconPNG = nil
        XCTAssertNil(try JSONDecoder().decode(CodeBuildApp.self, from: JSONEncoder().encode(app)).iconPNG)
    }
}
