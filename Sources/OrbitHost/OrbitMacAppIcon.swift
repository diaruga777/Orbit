import Foundation
import ImageIO

/// Read the installed bundle, so SwiftPM and Xcode Mac targets share one icon
/// source. The small PNG is sent through the existing catalog to both clients.
enum OrbitMacAppIcon {
    static func png(path: String, bundleID: String) -> Data? {
        let app = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              let name = info["CFBundleIconFile"] as? String, !name.isEmpty,
              URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
        let resources = app.appendingPathComponent("Contents/Resources")
        let file = resources.appendingPathComponent(name).pathExtension.isEmpty
            ? resources.appendingPathComponent(name + ".icns") : resources.appendingPathComponent(name)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 132,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
