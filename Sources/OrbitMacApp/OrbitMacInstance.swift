import AppKit

/// Redirect obsolete copies and focus the existing process before starting Host.
enum OrbitMacInstance {
    static func claim() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let canonical = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Orbit Mac.app")
        if Bundle.main.bundleURL.resolvingSymlinksInPath() != canonical.resolvingSymlinksInPath(),
           Bundle(url: canonical)?.bundleIdentifier == id {
            NSWorkspace.shared.openApplication(at: canonical, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return false
        }
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != getpid() }) {
            other.activate(options: [.activateAllWindows])
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return false
        }
        return true
    }
}
