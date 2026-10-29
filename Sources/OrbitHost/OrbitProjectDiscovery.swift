import Foundation

/// Filesystem metadata only: discovery never asks Xcode to load untrusted code.
public enum OrbitProjectDiscovery {
    public static func scan(roots: [URL], limit: Int = 500, maximumEntries: Int = 100_000) -> [String] {
        let fm = FileManager.default
        let excluded: Set<String> = ["Library", "Applications", "node_modules", "Pods", "Carthage", "DerivedData", "build", "dist", "Vendor"]
        var found = Set<String>(), visited = Set<String>(), remaining = maximumEntries
        for root in roots {
            let root = root.standardizedFileURL
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walker {
                remaining -= 1
                if remaining < 0 || found.count >= limit { return found.sorted() }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { walker.skipDescendants(); continue }
                guard values.isDirectory == true else { continue }
                if !visited.insert(url.path).inserted { walker.skipDescendants(); continue }
                if ["xcodeproj", "xcworkspace"].contains(url.pathExtension) {
                    found.insert(url.path); walker.skipDescendants()
                } else if excluded.contains(url.lastPathComponent) { walker.skipDescendants() }
            }
        }
        return found.sorted()
    }
}
