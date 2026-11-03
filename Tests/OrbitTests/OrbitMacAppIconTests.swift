import XCTest
import ImageIO
import CoreGraphics
@testable import OrbitHost
import OrbitCore

final class OrbitMacAppIconTests: XCTestCase {
    func testInstalledIconBackfillsMacCatalogAndRefreshesAfterUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Installed.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.installed.mac", "CFBundleIconFile": "Vault.png"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        func writeIcon(red: CGFloat) throws {
            let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(resources.appendingPathComponent("Vault.png") as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try writeIcon(red: 0.2)
        let first = try XCTUnwrap(OrbitMacAppIcon.png(path: app.path, bundleID: "test.installed.mac"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(first as CFData, nil))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(thumbnail.width, 132)
        XCTAssertNil(OrbitMacAppIcon.png(path: app.path, bundleID: "wrong.identity"))
        var target = OrbitTarget(name: "Mac", project: CodeProject(path: "/repo/App.xcodeproj", scheme: "Mac"), deviceID: "host-mac")
        target.mac = OrbitMacDeployment(installPath: app.path, bundleID: "test.installed.mac", certificate: "fixture", settings: Data("{}".utf8))
        try JSONEncoder().encode([target]).write(to: root.appendingPathComponent("targets.json"))
        var host: OrbitHost? = try OrbitHost(root: root)
        await host!.populateMissingTargetIcons { _ in XCTFail("Mac icons must not query iOS schemes"); return [] }
        let catalog = try JSONDecoder().decode([OrbitTarget].self, from: Data(contentsOf: root.appendingPathComponent("targets.json")))
        XCTAssertEqual(catalog.first?.iconPNG, first)
        host = nil
        try writeIcon(red: 0.9)
        let restarted = try OrbitHost(root: root)
        await restarted.populateMissingTargetIcons { _ in XCTFail("Mac icons must not query iOS schemes"); return [] }
        let response = await restarted.handle(Data(#"{"method":"targets"}"#.utf8))
        let result = try XCTUnwrap((JSONSerialization.jsonObject(with: response) as? [String: Any])?["result"] as? [[String: Any]])
        let refreshed = try XCTUnwrap(result.first?["iconPNG"] as? String)
        XCTAssertNotEqual(refreshed, first.base64EncodedString())
        XCTAssertEqual(refreshed, OrbitMacAppIcon.png(path: app.path, bundleID: "test.installed.mac")?.base64EncodedString())
        try FileManager.default.removeItem(at: resources.appendingPathComponent("Vault.png"))
        XCTAssertNil(OrbitMacAppIcon.png(path: app.path, bundleID: "test.installed.mac"))
    }
}
