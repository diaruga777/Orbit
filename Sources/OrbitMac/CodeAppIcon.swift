import Foundation
import ImageIO
import OrbitCore

enum CodeAppIcon {
    /// Use the target's configured icon set, never a scheme-name guess. Send a
    /// thumbnail so discovery and its persistent phone cache stay small.
    static func png(settings: [String: String], project: CodeProject) -> Data? {
        guard let name = settings["ASSETCATALOG_COMPILER_APPICON_NAME"], !name.isEmpty else { return nil }
        let root = URL(fileURLWithPath: settings["SRCROOT"] ?? project.root)
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in files {
            if ["build", "DerivedData", "Pods", "Carthage", "node_modules"].contains(url.lastPathComponent) {
                files.skipDescendants(); continue
            }
            guard url.lastPathComponent == name + ".appiconset" else { continue }
            files.skipDescendants()
            if let data = png(iconSet: url) { return data }
        }
        return nil
    }

    static func png(iconSet: URL) -> Data? {
        guard let data = try? Data(contentsOf: iconSet.appendingPathComponent("Contents.json")),
              let contents = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = contents["images"] as? [[String: Any]] else { return nil }
        // Prefer the full-size, default iOS appearance over dark/tinted variants.
        let candidates = images.filter {
            $0["appearances"] == nil && [nil, "ios"].contains($0["platform"] as? String) &&
            ["universal", "iphone", "ios-marketing", "ipad"].contains($0["idiom"] as? String ?? "")
        }.sorted { pixels($0) > pixels($1) }
        for entry in candidates {
            guard let filename = entry["filename"] as? String else { continue }
            let file = iconSet.appendingPathComponent(filename).standardizedFileURL
            guard file.deletingLastPathComponent() == iconSet.standardizedFileURL,
                  let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 132,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { continue }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { return output as Data }
        }
        return nil
    }
    private static func pixels(_ entry: [String: Any]) -> Double {
        let size = (entry["size"] as? String ?? "0").split(separator: "x").first.flatMap { Double($0) } ?? 0
        let scale = Double((entry["scale"] as? String ?? "1x").replacingOccurrences(of: "x", with: "")) ?? 1
        return size * scale
    }
}
