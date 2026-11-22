import Foundation
import ImageIO
import OrbitCore

enum CodeAppIcon {
    static func png(settings: [String: String], project: CodeProject) -> Data? {
        guard let targetName = settings["TARGET_NAME"],
              let root = settings["SRCROOT"] else { return nil }
        let projectFile = settings["PROJECT_FILE_PATH"].map { URL(fileURLWithPath: $0) }
        let projects = projectFile.map { [$0] } ?? CodeProjectPreview.projectContainers(path: project.path)
        for file in projects {
            guard let objects = CodeProjectPreview.projectObjects(file),
                  let target = objects.values.first(where: {
                      $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == targetName
                  }) else { continue }
            return png(target: target, objects: objects, settings: settings, root: URL(fileURLWithPath: root))
        }
        return nil
    }

    static func png(target: [String: Any], objects: [String: [String: Any]], settings: [String: String], root: URL) -> Data? {
        guard let name = settings["ASSETCATALOG_COMPILER_APPICON_NAME"], !name.isEmpty,
              (name as NSString).lastPathComponent == name else { return nil }
        func location(_ id: String, visited: Set<String> = []) -> URL? {
            guard !visited.contains(id), let object = objects[id] else { return nil }
            let path = object["path"] as? String ?? ""
            switch object["sourceTree"] as? String {
            case "SOURCE_ROOT": return root.appendingPathComponent(path)
            case "<absolute>": return URL(fileURLWithPath: path)
            case "<group>", nil:
                guard let parent = objects.first(where: { ($0.value["children"] as? [String])?.contains(id) == true })?.key else { return root.appendingPathComponent(path) }
                return location(parent, visited: visited.union([id]))?.appendingPathComponent(path)
            default: return nil
            }
        }
        let phases = (target["buildPhases"] as? [String] ?? []).compactMap { objects[$0] }
            .filter { $0["isa"] as? String == "PBXResourcesBuildPhase" }
        let resources = phases.flatMap { $0["files"] as? [String] ?? [] }.compactMap { objects[$0]?["fileRef"] as? String }
        for id in resources {
            guard let catalog = location(id), catalog.pathExtension == "xcassets" else { continue }
            if let icon = png(catalog: catalog, name: name) { return icon }
        }
        for id in target["fileSystemSynchronizedGroups"] as? [String] ?? [] {
            guard let folder = location(id),
                  let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let catalog as URL in files where catalog.pathExtension == "xcassets" {
                files.skipDescendants()
                if let icon = png(catalog: catalog, name: name) { return icon }
            }
        }
        return nil
    }

    private static func png(catalog: URL, name: String) -> Data? {
        let iconSet = name + ".appiconset"
        if let icon = png(iconSet: catalog.appendingPathComponent(iconSet)) { return icon }
        guard let files = FileManager.default.enumerator(at: catalog, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let set as URL in files where !set.pathExtension.isEmpty {
            files.skipDescendants()
            if set.lastPathComponent == iconSet, let icon = png(iconSet: set) { return icon }
        }
        return nil
    }

    static func png(builtApp: URL, info: [String: Any]) -> Data? {
        let names = ["CFBundleIcons", "CFBundleIcons~ipad"].flatMap { key -> [String] in
            let icons = info[key] as? [String: Any]
            let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
            return primary?["CFBundleIconFiles"] as? [String] ?? []
        } + (info["CFBundleIconFiles"] as? [String] ?? []) + [info["CFBundleIconFile"] as? String].compactMap { $0 }
        let stems = Set(names.map { $0.hasSuffix(".png") ? String($0.dropLast(4)) : $0 })
        guard !stems.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: builtApp, includingPropertiesForKeys: nil) else { return nil }
        // Xcode emits scale and device suffixes for the primary icon filenames in Info.plist.
        return files.filter { $0.pathExtension == "png" }.compactMap { file -> (Data, Int)? in
            let name = file.deletingPathExtension().lastPathComponent
            let stem = name.replacingOccurrences(of: #"(@[123]x)?(~(iphone|ipad))?$"#, with: "", options: .regularExpression)
            guard stems.contains(name) || stems.contains(stem) else { return nil }
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let data = thumbnail(source) else { return nil }
            return (data, width)
        }.max { $0.1 < $1.1 }?.0
    }

    static func png(iconSet: URL) -> Data? {
        guard let data = CodeProjectPreview.boundedData(iconSet.appendingPathComponent("Contents.json")),
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
                  let data = thumbnail(source) else { continue }
            return data
        }
        return nil
    }

    private static func thumbnail(_ source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 132,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func pixels(_ entry: [String: Any]) -> Double {
        let size = (entry["size"] as? String ?? "0").split(separator: "x").first.flatMap { Double($0) } ?? 0
        let scale = Double((entry["scale"] as? String ?? "1x").replacingOccurrences(of: "x", with: "")) ?? 1
        return size * scale
    }
}
