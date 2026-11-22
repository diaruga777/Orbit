import Foundation
import OrbitCore

enum CodeDeviceLocalChanges {
    static func supports(project: CodeProject, branch: String) -> Bool {
        !branch.hasPrefix("refs/remotes/") && !CodeOrbitIdentity.isOrbit(project)
    }

    /// Build a Git patch from the saved working files using a private index and
    /// object store. Apply it only to the detached checkout.
    static func apply(from repository: String, to checkout: URL, root: URL, process: CodeProcess, log: URL) async throws -> Bool {
        let files = FileManager.default
        let scratch = root.appendingPathComponent("LocalSource-" + UUID().uuidString)
        let objects = scratch.appendingPathComponent("objects")
        try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: scratch) }
        let info = objects.appendingPathComponent("info")
        try files.createDirectory(at: info, withIntermediateDirectories: true)
        let metadata = try await CodeDeviceSupport.git(["rev-parse", "--path-format=absolute", "--git-path", "objects"],
                                                       directory: repository, root: root, process: process)
        try Data((metadata + "\n").utf8).write(to: info.appendingPathComponent("alternates"))
        let environment = ["GIT_INDEX_FILE": scratch.appendingPathComponent("index").path, "GIT_OBJECT_DIRECTORY": objects.path]
        func git(_ arguments: [String]) async throws -> String {
            try await CodeDeviceSupport.git(["-c", "core.splitIndex=false"] + arguments,
                                            directory: repository, root: root, process: process, environment: environment)
        }
        let head = try await git(["rev-parse", "--verify", "HEAD^{commit}"])
        _ = try await git(["read-tree", head])
        _ = try await git(["add", "--all", "--", "."])
        let snapshot = try await git(["write-tree"])
        let patch = scratch.appendingPathComponent("changes.patch")
        let diff = try await process.run("/usr/bin/git",
            ["diff", "--binary", "--full-index", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color", "--ignore-submodules=all",
             "--src-prefix=a/", "--dst-prefix=b/", head, snapshot, "--"],
            directory: repository, log: log, timeout: 60, environmentOverrides: environment, standardOutput: patch)
        guard diff == 0 else { throw CodeFailure("Couldn’t capture local changes. See the build console for details.") }
        guard try patch.resourceValues(forKeys: [.fileSizeKey]).fileSize != 0 else { return false }
        let applied = try await process.run("/usr/bin/git",
            ["apply", "--binary", "--whitespace=nowarn", "--", patch.path], directory: checkout.path, log: log, timeout: 60)
        guard applied == 0 else {
            throw CodeFailure("Local changes don’t apply to the selected branch. Choose the checkout’s branch or resolve the conflict on your Mac.")
        }
        return true
    }
}
