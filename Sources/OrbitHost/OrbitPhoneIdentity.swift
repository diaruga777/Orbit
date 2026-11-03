import Foundation
import OrbitCore
import OrbitMac

/// A source-installed companion and its phone client share one local identity.
enum OrbitPhoneIdentity {
    static var canonicalSource: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "OrbitSourceRoot") as? String)
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
    }

    static func project(at source: URL) throws -> CodeProject {
        let project = CodeProject(path: source.appendingPathComponent("Orbit.xcodeproj").path, scheme: "Orbit")
        guard CodeOrbitIdentity.isOrbit(project) else { throw CodeFailure("Orbit’s source checkout is unavailable on your Mac.") }
        return try CodeOrbitIdentity.resolve(project)
    }

    static func reconcile(root: URL, source: URL, configuration: inout OrbitConfiguration, targets: inout [OrbitTarget]) throws {
        let canonical = try project(at: source)
        let source = source.resolvingSymlinksInPath()
        let privateRoot = root.appendingPathComponent("PhoneSource").resolvingSymlinksInPath().path + "/"
        let selected = targets.indices.filter {
            let project = targets[$0].project
            let path = URL(fileURLWithPath: project.root).resolvingSymlinksInPath().path
            return targets[$0].mac == nil && CodeOrbitIdentity.isOrbit(project) &&
                (path == source.path || path.hasPrefix(privateRoot))
        }
        let changed = selected.filter { targets[$0].project.path != canonical.path ||
            targets[$0].project.bundlePrefix != canonical.bundlePrefix ||
            targets[$0].project.developmentTeam != canonical.developmentTeam ||
            targets[$0].project.iosBundleID != canonical.iosBundleID }
        guard changed.allSatisfy({ targets[$0].jobID == nil && targets[$0].pendingRequest == nil }) else {
            throw CodeFailure("Finish the active Orbit build, then reopen Orbit Mac to use its canonical identity.")
        }
        var updated = targets
        for index in changed {
            let old = updated[index].project
            var project = old
            project.path = canonical.path; project.bundlePrefix = canonical.bundlePrefix
            project.developmentTeam = canonical.developmentTeam; project.iosBundleID = canonical.iosBundleID
            updated[index].project = project
            updated[index].repository = nil
            if (old.iosBundleID ?? old.bundlePrefix.map { $0 + ".ios" }) != canonical.iosBundleID {
                // The old success belongs to another installed app. Keep its job history.
                updated[index].lastSuccess = nil
                updated[index].lastAttempt = Date()
            }
            updated[index].failure = nil
        }
        var config = configuration; config.phoneBundleID = canonical.iosBundleID
        // Persist the target before configuration. A partial write still fails closed
        // at the build/install identity checks and is repaired on the next launch.
        try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("targets.json"), options: .atomic)
        try JSONEncoder().encode(config).write(to: root.appendingPathComponent("config.json"), options: .atomic)
        targets = updated; configuration = config
    }
}
