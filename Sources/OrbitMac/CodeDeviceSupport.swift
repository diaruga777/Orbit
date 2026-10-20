import Foundation
import OrbitCore

/// Xcode/CoreDevice commands only. No UI automation agent is installed on phones.
enum CodeDeviceSupport {
    static func json(_ executable: String, _ arguments: [String], directory: String, root: URL,
                     process: CodeProcess = CodeProcess(), timeout: TimeInterval = 120, nonBuildableScheme: String? = nil) async throws -> Any {
        let log = root.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: log) }
        let status = try await process.run(executable, arguments, directory: directory, log: log, timeout: timeout)
        let data = try Data(contentsOf: log)
        return try queryResult(data, status: status, nonBuildableScheme: nonBuildableScheme)
    }
    static func queryResult(_ data: Data, status: Int32, nonBuildableScheme: String? = nil) throws -> Any {
        // Package schemes can appear in -list even though they have no Build
        // action. They are not failed app queries and must not abort discovery.
        if status != 0, let scheme = nonBuildableScheme,
           String(decoding: data, as: UTF8.self).contains("xcodebuild: error: Scheme " + scheme + " is not currently configured for the build action.") {
            return [[String: Any]]()
        }
        guard status == 0 else { throw CodeFailure("Xcode could not read project details. Open the project on the Mac to resolve packages and signing.\n" + String(decoding: data.suffix(2000), as: UTF8.self)) }
        return try parseJSONOutput(data)
    }
    static func parseJSONOutput(_ data: Data) throws -> Any {
        // Xcode can prepend timestamped warnings containing [MT] or package
        // progress. Find the complete JSON document rather than its first bracket.
        for start in data.indices where data[start] == 123 || data[start] == 91 {
            if let object = try? JSONSerialization.jsonObject(with: data.suffix(from: start)) { return object }
        }
        throw CodeFailure("Xcode returned no readable project details.\n" + String(decoding: data.suffix(2000), as: UTF8.self))
    }
    static func schemes(path: String, root: URL) async throws -> [String] {
        let object = try await json("/usr/bin/xcodebuild", [path.hasSuffix(".xcworkspace") ? "-workspace" : "-project", path, "-list", "-json"], directory: (path as NSString).deletingLastPathComponent, root: root) as? [String: Any]
        let project = object?["workspace"] as? [String: Any] ?? object?["project"] as? [String: Any]
        return project?["schemes"] as? [String] ?? []
    }
    static func settings(_ project: CodeProject, root: URL, process: CodeProcess = CodeProcess(), destination: String? = nil) async throws -> [[String: String]] {
        let rows = try await json("/usr/bin/xcodebuild", project.xcodeArguments + ["-configuration", "Debug"] + (destination.map { ["-destination", $0] } ?? []) + ["-showBuildSettings", "-json"], directory: project.root, root: root, process: process, nonBuildableScheme: project.scheme) as? [[String: Any]] ?? []
        return rows.compactMap { $0["buildSettings"] as? [String: String] }
    }
    static func isApp(_ settings: [String: String]) -> Bool {
        settings["PRODUCT_TYPE"] == "com.apple.product-type.application" &&
        (settings["SUPPORTED_PLATFORMS"] ?? settings["PLATFORM_NAME"] ?? "").components(separatedBy: " ").contains("iphoneos")
    }
    static func primarySettings(_ settings: [[String: String]], project: CodeProject) throws -> [String: String]? {
        if let target = try runnableTarget(path: project.path, scheme: project.scheme) {
            return settings.first { $0["TARGET_NAME"] == target }
        }
        return settings.first
    }
    static func apps(path: String, scheme selectedScheme: String? = nil, root: URL) async throws -> [CodeBuildApp] {
        var apps: [CodeBuildApp] = []
        let available: [String]
        if let selectedScheme { available = [selectedScheme] }
        else { available = try await schemes(path: path, root: root) }
        for scheme in available where !scheme.lowercased().contains("webdriveragent") {
            let project = CodeProject(path: path, scheme: scheme)
            // Explicit test-only / aggregate schemes have no runnable product.
            // Skip before invoking Xcode; automatic package schemes are filtered
            // by the no-Build-action result in settings().
            if try runnableTarget(path: path, scheme: scheme) == "" { continue }
            let settings = try await settings(project, root: root)
            // An explicit scheme's Run action identifies its app even when
            // build settings put a dependency first. Automatic schemes use
            // Xcode's primary (first) target and never search dependencies.
            let primary = try primarySettings(settings, project: project)
            if let app = primary, isApp(app), let bundle = app["PRODUCT_BUNDLE_IDENTIFIER"], !bundle.lowercased().contains("webdriveragent") {
                var row = CodeBuildApp(project: project, name: app["PRODUCT_NAME"] ?? scheme, bundleID: bundle)
                row.iconPNG = CodeAppIcon.png(settings: app, project: project)
                apps.append(row)
            }
        }
        return apps
    }
    static func runnableTarget(path: String, scheme: String) throws -> String? {
        let container = URL(fileURLWithPath: path)
        var containers = [container]
        if container.pathExtension == "xcworkspace" {
            containers += (try? FileManager.default.contentsOfDirectory(at: container.deletingLastPathComponent(), includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "xcodeproj" } ?? []
        }
        for container in containers {
            let shared = container.appendingPathComponent("xcshareddata/xcschemes/" + scheme + ".xcscheme")
            var candidates = [shared]
            let users = container.appendingPathComponent("xcuserdata")
            for user in (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
                candidates.append(user.appendingPathComponent("xcschemes/" + scheme + ".xcscheme"))
            }
            for file in candidates where FileManager.default.fileExists(atPath: file.path) {
                return try parseRunnableTarget(Data(contentsOf: file)) ?? ""
            }
        }
        return nil
    }
    static func parseRunnableTarget(_ data: Data) throws -> String? {
        let delegate = SchemeRunnable()
        let parser = XMLParser(data: data); parser.delegate = delegate
        guard parser.parse() else { throw CodeFailure("Could not read this Xcode scheme. Open it on your Mac and check its Run action.") }
        // A scheme that runs one dependency but builds several apps is a
        // collection (for example AllOrbitApps), not an individual app row.
        return delegate.appTargets.count > 1 ? nil : delegate.target
    }
    static func devices(root: URL) async throws -> [CodeDevice] {
        let log = root.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: log) }
        // CoreDevice's tunnel can be disconnected while Xcode still reports a
        // paired phone as available. Xcode opens that tunnel on demand for a
        // wireless build/install; requiring it here hides reachable phones.
        let status = try await CodeProcess().run("/usr/bin/xcrun", ["xcdevice", "list", "--timeout", "5"], directory: root.path, log: log, timeout: 30)
        guard status == 0 else { throw CodeFailure("Could not list phones. Check Xcode and the device connection on the Mac.") }
        return try parseDevices(Data(contentsOf: log))
    }
    static func parseDevices(_ data: Data) throws -> [CodeDevice] {
        guard let devices = try parseJSONOutput(data) as? [[String: Any]] else {
            throw CodeFailure("Xcode returned no readable phone list. Check Xcode on the Mac, then try again.")
        }
        return devices.compactMap { device in
            guard device["simulator"] as? Bool == false,
                  device["platform"] as? String == "com.apple.platform.iphoneos",
                  device["available"] as? Bool == true, device["error"] == nil,
                  device["ignored"] as? Bool != true,
                  let id = device["identifier"] as? String, !id.isEmpty,
                  let name = device["name"] as? String, !name.isEmpty else { return nil }
            return CodeDevice(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func validateDestination(_ project: CodeProject, deviceID: String, root: URL, process: CodeProcess) async throws {
        let log = root.appendingPathComponent(UUID().uuidString + ".destinations")
        defer { try? FileManager.default.removeItem(at: log) }
        let status = try await process.run("/usr/bin/xcodebuild", project.xcodeArguments + ["-showdestinations", "-destination-timeout", "10"], directory: project.root, log: log, timeout: 45)
        let output = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        guard status == 0, destinationIsEligible(output, deviceID: deviceID) else {
            throw CodeFailure("This phone is not available for \(project.scheme). Connect it to your Mac by cable or on the same network and unlock it. In Xcode’s Devices and Simulators, check pairing, Developer Mode, iOS support and the scheme’s deployment target.")
        }
    }
    static func destinationIsEligible(_ output: String, deviceID: String) -> Bool {
        var available = false
        for line in output.components(separatedBy: "\n") {
            if line.contains("Ineligible destinations") { available = false }
            else if line.contains("Available destinations") { available = true }
            guard available, let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}") else { continue }
            let fields = line[line.index(after: start)..<end].split(separator: ",").reduce(into: [String: String]()) { result, field in
                let parts = field.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { result[parts[0]] = parts[1] }
            }
            if fields["platform"] == "iOS", fields["id"] == deviceID, fields["error"] == nil { return true }
        }
        return false
    }
    static func git(_ arguments: [String], directory: String, root: URL, process: CodeProcess = CodeProcess()) async throws -> String {
        let log = root.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: log) }
        let status = try await process.run("/usr/bin/git", arguments, directory: directory, log: log, timeout: 60)
        let output = String(decoding: try Data(contentsOf: log), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else { throw CodeFailure("Git: " + output) }
        return output
    }
    static func branches(path: String, root: URL) async throws -> [String] {
        let output = try await git(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"], directory: (path as NSString).deletingLastPathComponent, root: root)
        return output.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
    }
}

private final class SchemeRunnable: NSObject, XMLParserDelegate {
    var target: String?
    var appTargets: Set<String> = []
    private var buildsForRunning = false
    private var elements: [String] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        elements.append(elementName)
        if elementName == "BuildActionEntry" { buildsForRunning = attributes["buildForRunning"] == "YES" }
        if elementName == "BuildableReference", elements.contains("BuildAction"), buildsForRunning,
           attributes["BuildableName"]?.hasSuffix(".app") == true, let name = attributes["BlueprintName"] {
            appTargets.insert(name)
        }
        if elementName == "BuildableReference", elements.contains("LaunchAction"), elements.contains("BuildableProductRunnable") {
            target = attributes["BlueprintName"]
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { elements.removeLast() }
}
