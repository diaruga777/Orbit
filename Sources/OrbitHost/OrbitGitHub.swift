import Foundation
import OrbitCore

public enum OrbitCommand {
    public static func run(_ executable: String, _ arguments: [String], directory: URL? = nil) async throws -> Data {
        try await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.currentDirectoryURL = directory
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-command-" + UUID().uuidString)
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: file); defer { try? output.close(); try? FileManager.default.removeItem(at: file) }
            process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
            try process.run()
            let timer = DispatchSource.makeTimerSource(); timer.schedule(deadline: .now() + 180)
            timer.setEventHandler { if process.isRunning { process.terminate() } }; timer.resume(); defer { timer.cancel() }
            process.waitUntilExit()
            let data = try Data(contentsOf: file)
            guard process.terminationStatus == 0 else { throw CodeFailure(String(decoding: data.suffix(6000), as: UTF8.self)) }
            guard data.count <= 24 * 1024 * 1024 else { throw CodeFailure("Command output exceeded its limit.") }
            return data
        }.value
    }
}
public enum OrbitGitHub {
    public static func repository(_ value: String) throws -> String {
        var name = value
        if let url = URL(string: value), url.scheme != nil {
            guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil else { throw CodeFailure("Use a github.com HTTPS URL or owner/repository.") }
            name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if name.hasSuffix(".git") { name.removeLast(4) }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { throw CodeFailure("Use owner/repository or its GitHub URL.") }
        return name
    }
    private static func get(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var url = URLComponents(string: "https://api.github.com/" + path)!; url.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: url.url!); request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Orbit/0.1", forHTTPHeaderField: "User-Agent")
        // Opt-in GitHub token stays on the Mac; it is never returned in RPC.
        if let token = ProcessInfo.processInfo.environment["GH_TOKEN"] { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CodeFailure("GitHub could not read this repository. Check its name, access and API rate limit.") }
        guard data.count <= 24 * 1024 * 1024 else { throw CodeFailure("Repository tree is too large to inspect automatically.") }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    public static func search(_ query: String) async throws -> [[String: Any]] {
        let response = try await get("search/repositories", query: [.init(name: "q", value: query), .init(name: "per_page", value: "20")])
        return (response["items"] as? [[String: Any]] ?? []).map { ["repository": $0["full_name"] ?? "", "description": $0["description"] ?? NSNull(), "url": $0["html_url"] ?? "", "stars": $0["stargazers_count"] ?? 0] }
    }
    public static func inspect(_ input: String) async throws -> [String: Any] {
        let name = try repository(input)
        let metadata = try await get("repos/" + name)
        guard let branch = metadata["default_branch"] as? String else { throw CodeFailure("Repository has no default branch.") }
        let ref = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let tree = try await get("repos/" + name + "/git/trees/" + ref, query: [.init(name: "recursive", value: "1")])
        guard tree["truncated"] as? Bool != true else { throw CodeFailure("GitHub truncated the tree. Clone and inspect the repository locally.") }
        let paths = (tree["tree"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        let projects = paths.filter { $0.hasSuffix(".xcodeproj/project.pbxproj") }.map { String($0.dropLast("/project.pbxproj".count)) }
        let workspaces = paths.filter { $0.hasSuffix(".xcworkspace/contents.xcworkspacedata") && !$0.contains(".xcodeproj/") }.map { String($0.dropLast("/contents.xcworkspacedata".count)) }
        return ["repository": name, "defaultBranch": branch, "compatible": !projects.isEmpty,
            "projects": workspaces + projects, "sharedSchemes": paths.filter { $0.contains("/xcshareddata/xcschemes/") && $0.hasSuffix(".xcscheme") },
            "check": "Xcode project found. Adding a target also checks for a runnable iOS app scheme on your Mac."]
    }
}
