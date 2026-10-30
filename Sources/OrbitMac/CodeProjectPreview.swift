import Foundation
import OrbitCore

/// Inert previews only. No Xcode invocation, package resolution or repository code.
/// Registration still validates the selected scheme with Xcode after source consent.
public enum CodeProjectPreview {
    public static func apps(path: String) -> [CodeBuildApp] {
        let container = URL(fileURLWithPath: path)
        return projectContainers(path: path).flatMap { preview(project: $0, container: container) }
            .sorted { $0.project.scheme < $1.project.scheme }
    }
    static func projectContainers(path: String) -> [URL] {
        let container = URL(fileURLWithPath: path)
        let projects: [URL]
        if container.pathExtension == "xcworkspace" {
            let reader = WorkspaceProjects(base: container.deletingLastPathComponent())
            if let data = boundedData(container.appendingPathComponent("contents.xcworkspacedata")) {
                let parser = XMLParser(data: data); parser.delegate = reader; _ = parser.parse()
            }
            projects = reader.projects
        } else { projects = [container] }
        return projects
    }

    private static func preview(project: URL, container: URL) -> [CodeBuildApp] {
        guard let data = boundedData(project.appendingPathComponent("project.pbxproj")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]] else { return [] }
        func settings(_ object: [String: Any]) -> [String: String] {
            guard let list = object["buildConfigurationList"] as? String,
                  let ids = objects[list]?["buildConfigurations"] as? [String] else { return [:] }
            let configs = ids.compactMap { objects[$0] }
            let config = configs.first { $0["name"] as? String == "Debug" } ?? configs.first
            return (config?["buildSettings"] as? [String: Any] ?? [:]).reduce(into: [:]) { result, entry in
                if let text = entry.value as? String { result[entry.key] = text }
                else if let parts = entry.value as? [String] { result[entry.key] = parts.joined(separator: " ") }
            }
        }
        let global = objects.values.first { $0["isa"] as? String == "PBXProject" }.map(settings) ?? [:]
        let targets = objects.values.filter { $0["isa"] as? String == "PBXNativeTarget" && $0["productType"] as? String == "com.apple.product-type.application" }
        var rows: [CodeBuildApp] = []
        let schemes = schemeNames(container) + (container == project ? [] : schemeNames(project))
        for target in targets {
            guard let name = target["name"] as? String, !name.lowercased().contains("webdriveragent") else { continue }
            var config = global.merging(settings(target)) { _, target in target }
            let platforms = config["SUPPORTED_PLATFORMS"] ?? config["SDKROOT"] ?? ""
            guard platforms.contains("iphoneos") else { continue }
            config["SRCROOT"] = project.deletingLastPathComponent().path
            let candidates = Set(schemes + [name])
            for scheme in candidates.sorted() where !scheme.lowercased().contains("webdriveragent") {
                let runnable = try? CodeDeviceSupport.runnableTarget(path: container.path, scheme: scheme)
                // Auto-created schemes have the target's name. Never borrow an app dependency.
                guard runnable == name || (runnable == nil && scheme == name) else { continue }
                let projectValue = CodeProject(path: container.path, scheme: scheme)
                var row = CodeBuildApp(project: projectValue, name: name, bundleID: config["PRODUCT_BUNDLE_IDENTIFIER"] ?? "")
                row.iconPNG = icon(target: target, objects: objects, settings: config, project: projectValue)
                row.branch = branch(at: project.deletingLastPathComponent())
                rows.append(row)
            }
        }
        return rows
    }
    private static func icon(target: [String: Any], objects: [String: [String: Any]], settings: [String: String], project: CodeProject) -> Data? {
        guard let name = settings["ASSETCATALOG_COMPILER_APPICON_NAME"] else { return nil }
        let root = URL(fileURLWithPath: settings["SRCROOT"] ?? project.root)
        func location(_ id: String, visited: Set<String> = []) -> URL? {
            guard !visited.contains(id), let object = objects[id] else { return nil }
            let path = object["path"] as? String ?? ""
            if object["sourceTree"] as? String == "SOURCE_ROOT" { return root.appendingPathComponent(path) }
            if object["sourceTree"] as? String == "<absolute>" { return URL(fileURLWithPath: path) }
            let parent = objects.first { ($0.value["children"] as? [String])?.contains(id) == true }?.key
            return (parent.flatMap { location($0, visited: visited.union([id])) } ?? root).appendingPathComponent(path)
        }
        let phases = (target["buildPhases"] as? [String] ?? []).compactMap { objects[$0] }.filter { $0["isa"] as? String == "PBXResourcesBuildPhase" }
        let resources = phases.flatMap { $0["files"] as? [String] ?? [] }.compactMap { objects[$0]?["fileRef"] as? String }
        for id in resources {
            if let url = location(id), url.pathExtension == "xcassets",
               let png = CodeAppIcon.png(iconSet: url.appendingPathComponent(name + ".appiconset")) { return png }
        }
        for id in target["fileSystemSynchronizedGroups"] as? [String] ?? [] {
            if let url = location(id) {
                var scoped = settings; scoped["SRCROOT"] = url.path
                if let png = CodeAppIcon.png(settings: scoped, project: project) { return png }
            }
        }
        return CodeAppIcon.png(settings: settings, project: project)
    }
    private static func schemeNames(_ container: URL) -> [String] {
        var folders = [container.appendingPathComponent("xcshareddata/xcschemes")]
        let users = container.appendingPathComponent("xcuserdata")
        for user in (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            folders.append(user.appendingPathComponent("xcschemes"))
        }
        return folders.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "xcscheme" }.map { $0.deletingPathExtension().lastPathComponent }
    }
    static func boundedData(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }
    private static func branch(at start: URL) -> String {
        var directory = start
        while directory.path != "/" {
            var git = directory.appendingPathComponent(".git")
            if let data = boundedData(git), let text = String(data: data, encoding: .utf8), text.hasPrefix("gitdir: ") {
                git = URL(fileURLWithPath: String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: directory).standardizedFileURL
            }
            if let data = boundedData(git.appendingPathComponent("HEAD")), let text = String(data: data, encoding: .utf8), text.hasPrefix("ref: refs/heads/") {
                return String(text.dropFirst(16)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            directory.deleteLastPathComponent()
        }
        return "main"
    }
}

private final class WorkspaceProjects: NSObject, XMLParserDelegate {
    let base: URL
    var projects: [URL] = []
    var groups: [URL] = []
    init(base: URL) { self.base = base }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let parent = groups.last ?? base
        let location = attributes["location"] ?? "group:"
        let parts = location.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.count == 2 ? String(parts[1]) : ""
        let url = parts.first == "absolute" ? URL(fileURLWithPath: path) : (parts.first == "container" ? base : parent).appendingPathComponent(path).standardizedFileURL
        if element == "Group" { groups.append(url) }
        if element == "FileRef", url.pathExtension == "xcodeproj", projects.count < 100 { projects.append(url) }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "Group", !groups.isEmpty { groups.removeLast() }
    }
}
