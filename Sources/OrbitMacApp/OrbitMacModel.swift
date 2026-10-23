import SwiftUI
import AppKit
import OrbitHost
import UniformTypeIdentifiers

@MainActor final class OrbitMacModel: ObservableObject {
    @Published var applets: [[String: String]] = []
    @Published var widgets: [[String: String]] = []
    @Published var appletFolder = ""
    @Published var widgetFolder = ""
    @Published var scriptMessage = ""
    @Published var scriptIssues: [String] = []
    @Published var scriptImportFailed = false
    @Published var status = "Starting…"
    @Published var pairing = ""
    @Published var targets: [[String: Any]] = []
    @Published var query = ""
    @Published var results: [[String: Any]] = []
    @Published var inspection: [String: Any]?
    @Published var project = ""
    @Published var scheme = ""
    @Published var phone = ""
    @Published var team = ""
    @Published var branch = "main"
    @Published var scheduled = true
    @Published var hours = "144"
    @Published var personal = true
    let mcp = OrbitMCPService()
    var host: OrbitHost?
    var server: OrbitServer?
    init() {
        Task {
            do {
                let host = try OrbitHost(); self.host = host
                let server = OrbitServer(host: host, root: OrbitPaths.root); self.server = server
                server.approve = { peer in await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert(); alert.messageText = "Connect this phone to Orbit?"
                    alert.informativeText = "It can edit files, add app targets, and run builds using your Mac’s tools and signing account. Compare this phone ID before accepting.\n\n" + peer
                    alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
                    return alert.runModal() == .alertFirstButtonReturn
                } }
                do { try await server.start(); status = "Ready" }
                catch { status = error.localizedDescription }
                while !Task.isCancelled { await mcp.startIfNeeded(); await refresh(); try? await Task.sleep(for: .seconds(5)) }
            } catch { status = error.localizedDescription }
        }
    }
    func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        guard let host else { throw NSError(domain: "Orbit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Orbit is starting."]) }
        let data = await host.handle(try JSONSerialization.data(withJSONObject: ["method": method, "params": params]))
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let error = response["error"] as? String { throw NSError(domain: "Orbit", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
        return response["result"] ?? NSNull()
    }
    func refresh() async {
        targets = (try? await rpc("targets")) as? [[String: Any]] ?? []
        await refreshScripts()
    }
    func refreshScripts() async {
        do {
            let state = try await rpc("script_status") as? [String: Any] ?? [:]
            appletFolder = state["appletFolder"] as? String ?? ""
            widgetFolder = state["widgetFolder"] as? String ?? ""
            scriptIssues = state["issues"] as? [String] ?? []
            applets = try await rpc("applets") as? [[String: String]] ?? []
            widgets = try await rpc("widgets") as? [[String: String]] ?? []
        } catch { scriptMessage = error.localizedDescription }
    }
    func importScripts(_ urls: [URL]) async {
        var failures: [String] = [], count = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            do {
                guard url.isFileURL, url.pathExtension.lowercased() == "js" else { throw NSError(domain: "Orbit", code: 3, userInfo: [NSLocalizedDescriptionKey: "Choose an Orbit .js file."]) }
                _ = try await rpc("script_import", ["path": url.path]); count += 1
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            if access { url.stopAccessingSecurityScopedResource() }
        }
        scriptMessage = failures.isEmpty ? "\(count) imported. Your iPhone will receive them when Orbit is open and connected." : failures.joined(separator: "\n")
        scriptImportFailed = !failures.isEmpty
        await refreshScripts()
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !files.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in files {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url { urls.append(url) }
            }
            if urls.isEmpty { scriptMessage = "Couldn’t read those files. Try Add JavaScript."; scriptImportFailed = true }
            else { await importScripts(urls) }
        }
        return true
    }
    func pair() { Task { await host?.openPairing(); pairing = (try? await server?.pairingCode()) ?? "" } }
    func search() { Task { do { results = try await rpc("repo_search", ["query": query]) as? [[String: Any]] ?? [] } catch { status = error.localizedDescription } } }
    func inspect(_ repository: String) { Task { do { inspection = try await rpc("repo_inspect", ["repository": repository]) as? [String: Any] } catch { status = error.localizedDescription } } }
    func add(repository: String? = nil) {
        let alert = NSAlert(); alert.messageText = "Build this source on your Mac?"
        alert.informativeText = "Xcode projects can run scripts with your Mac account’s permissions. Only add source you trust."
        alert.addButton(withTitle: "Add App"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do {
            var params: [String: Any] = ["project": project, "scheme": scheme, "deviceID": phone, "branch": branch, "teamID": team, "enabled": scheduled, "intervalHours": Int(hours) ?? 144, "trust": true, "account": personal ? "free" : "paid"]
            if let repository { params["repository"] = repository }
            _ = try await rpc(repository == nil ? "target_add" : "repo_add", params); status = "App added"; await refresh()
        } catch { status = error.localizedDescription } }
    }
}
