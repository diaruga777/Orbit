import Foundation
import OrbitWidgets

/// Owned by OrbitHost. The selected folders are the catalog; scanning never runs code.
final class OrbitScriptLibrary {
    struct Entry {
        let file: OrbitJavaScriptFile
        let url: URL
        let modified: Date
        var object: [String: String] {
            ["id": file.script.id, "name": file.script.definition.name, "source": file.script.source,
             "digest": OrbitWidgetDefinition.digest(file.script.source)]
        }
    }
    private(set) var entries: [Entry] = []
    private(set) var issues: [String] = []
    func scan(_ folders: [OrbitJavaScriptFile.Kind: URL]) {
        var found: [Entry] = [], failures: [String] = []
        for folder in Set(folders.values).sorted(by: { $0.path < $1.path }) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension.lowercased() == "js" }.sorted { $0.path < $1.path }
                if urls.count > 256 { failures.append("\(folder.lastPathComponent): only the first 256 JavaScript files are checked.") }
                for url in urls.prefix(256) {
                    do {
                        found.append(Entry(file: try OrbitJavaScriptFile(url: url), url: url,
                                           modified: try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast))
                    } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
            } catch { failures.append("\(folder.path): \(error.localizedDescription)") }
        }
        // The latest saved file wins for duplicate IDs, independently for each kind.
        found.sort { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified }
        var seen = Set<String>(), counts: [OrbitJavaScriptFile.Kind: Int] = [:]
        entries = found.filter {
            let key = $0.file.kind.rawValue + ":" + $0.file.script.id
            guard seen.insert(key).inserted else { failures.append("\($0.url.lastPathComponent): another file has this \($0.file.kind.rawValue) ID."); return false }
            counts[$0.file.kind, default: 0] += 1
            guard counts[$0.file.kind, default: 0] <= 24 else { failures.append("\($0.url.lastPathComponent): remove a \($0.file.kind.rawValue) before adding another."); return false }
            return true
        }.sorted { $0.file.script.id < $1.file.script.id }
        issues = failures
    }
    func list(_ kind: OrbitJavaScriptFile.Kind) -> [[String: String]] { entries.filter { $0.file.kind == kind }.map(\.object) }
    func add(_ file: OrbitJavaScriptFile, folders: [OrbitJavaScriptFile.Kind: URL]) throws -> [String: Any] {
        scan(folders)
        let current = entries.filter { $0.file.kind == file.kind }
        guard current.count < 24 || current.contains(where: { $0.file.script.id == file.script.id }) else { throw OrbitWidgetError("Remove a \(file.kind.rawValue) before adding another.") }
        let folder = folders[file.kind]!
        // Preserve the user's filename when updating an existing file in its selected folder.
        let destination = current.first { $0.file.script.id == file.script.id && $0.url.deletingLastPathComponent() == folder }?.url
            ?? folder.appendingPathComponent(file.script.id + ".js")
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try OrbitJavaScriptFile(url: destination)
            guard existing.kind == file.kind, existing.script.id == file.script.id else { throw OrbitWidgetError("A different file already uses \(destination.lastPathComponent). Rename it first.") }
        }
        try Data(file.script.source.utf8).write(to: destination, options: .atomic)
        scan(folders)
        return ["id": file.script.id, "name": file.script.definition.name, "kind": file.kind.rawValue,
                "path": destination.path, "pendingPhoneApproval": true]
    }
    func remove(_ id: String, kind: OrbitJavaScriptFile.Kind, folders: [OrbitJavaScriptFile.Kind: URL]) throws {
        scan(folders)
        guard entries.contains(where: { $0.file.kind == kind && $0.file.script.id == id }) else { throw OrbitWidgetError("\(kind.rawValue.capitalized) not found.") }
        // Remove duplicates too, so an older version cannot reappear at the next scan.
        for folder in Set(folders.values) {
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension.lowercased() == "js" {
                if let file = try? OrbitJavaScriptFile(url: url), file.kind == kind, file.script.id == id { try FileManager.default.removeItem(at: url) }
            }
        }
        scan(folders)
    }
    func migrate(from old: [OrbitJavaScriptFile.Kind: URL], to new: [OrbitJavaScriptFile.Kind: URL]) throws {
        scan(old)
        for entry in entries {
            let folder = new[entry.file.kind]!
            guard folder != entry.url.deletingLastPathComponent() else { continue }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(entry.file.script.id + ".js")
            if !FileManager.default.fileExists(atPath: destination.path) { try Data(entry.file.script.source.utf8).write(to: destination, options: .atomic) }
        }
        scan(new)
    }
}
