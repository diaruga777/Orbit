import SwiftUI
import AppKit
import OrbitHost
import OrbitCore
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
    @Published var detectedProjects: [String] = []
    @Published var previews: [String: [CodeBuildApp]] = [:]
    @Published var selectedTab = "applets"
    @Published var addSource = "local"
    @Published var adding = false
    @Published var addError = ""
    @Published var addedName = ""
    @Published var searching = false
    @Published var inspectingRepository = false
    @Published var downloading = false
    @Published var repositoryProjects: [String] = []
    @Published var preparedRepository: String?
    @Published var phones: [CodeDevice] = []
    @Published var loadingPhones = false
    @Published var phoneError = ""
    private var targetRevision = 0
    private var inspectionRevision = 0
    private let previewURL = OrbitPaths.root.appendingPathComponent("project-previews-v1.json")
    var selectedApps: [CodeBuildApp] { previews[project] ?? [] }
    var appChoices: [CodeBuildApp] { CodeBuildApp.registrationChoices(selectedApps) }
    var selectedChoice: String {
        guard let app = selectedApp else { return "" }
        return appChoices.first { $0.registrationIdentity == app.registrationIdentity }?.project.scheme ?? ""
    }
    var schemeVariants: [CodeBuildApp] {
        guard let app = selectedApp else { return [] }
        return selectedApps.filter { $0.registrationIdentity == app.registrationIdentity }
    }
    var selectedApp: CodeBuildApp? { selectedApps.first { $0.project.scheme == scheme } }
    var canAdd: Bool {
        !adding && !readingSchemes && selectedApp != nil && !project.isEmpty && !phone.isEmpty &&
        (Int(hours).map { (1...(personal ? 144 : 8760)).contains($0) } ?? false) && !branch.trimmingCharacters(in: .whitespaces).isEmpty
    }
    @Published var detecting = false
    @Published var readingSchemes = false
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
        if let data = try? Data(contentsOf: previewURL), let cache = try? JSONDecoder().decode([String: [CodeBuildApp]].self, from: data) {
            previews = cache; detectedProjects = cache.keys.sorted()
        }
        Task {
            do {
                let host = try OrbitHost(); self.host = host
                let server = OrbitServer(host: host, root: OrbitPaths.root); self.server = server
                await server.setApproval { peer in await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert(); alert.messageText = "Connect this phone to Orbit?"
                    alert.informativeText = "It can edit files, add app targets, and run builds using your Mac’s tools and signing account. Compare this phone ID before accepting.\n\n" + peer
                    alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
                    return alert.runModal() == .alertFirstButtonReturn
                } }
                do { try await server.start(); status = "Ready" }
                catch { status = error.localizedDescription }
                Task { await detectProjects() }
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
        let revision = targetRevision
        do {
            let rows = try await rpc("targets") as? [[String: Any]] ?? []
            if revision == targetRevision { targets = rows }
        } catch { status = error.localizedDescription }
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
    func detectProjects() async {
        guard !detecting else { return }
        detecting = true
        defer { detecting = false }
        do {
            let paths = try await rpc("projects_detect") as? [String] ?? []
            // Keep explicitly chosen projects as well as automatically discovered ones.
            detectedProjects = Array(Set(paths + (project.isEmpty ? [] : [project]))).sorted()
            for path in detectedProjects {
                let rows = try await preview(path)
                if !(project == path && readingSchemes) { previews[path] = rows }
            }
            let cache = previews.filter { detectedProjects.contains($0.key) }
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: previewURL, options: .atomic) }
        } catch { addError = error.localizedDescription }
    }
    private func savePreviews() {
        if let data = try? JSONEncoder().encode(previews) { try? data.write(to: previewURL, options: .atomic) }
    }
    private func preview(_ path: String) async throws -> [CodeBuildApp] {
        let rows = try await rpc("project_preview", ["project": path])
        return try JSONDecoder().decode([CodeBuildApp].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    func loadPhones(preferred: String) async {
        guard !loadingPhones else { return }
        if phone.isEmpty { phone = UserDefaults.standard.string(forKey: "Orbit.lastAppPhone") ?? preferred }
        loadingPhones = true; phoneError = ""
        defer { loadingPhones = false }
        do {
            let rows = try await rpc("devices")
            phones = try JSONDecoder().decode([CodeDevice].self, from: JSONSerialization.data(withJSONObject: rows))
            if phone.isEmpty { phone = phones.first?.id ?? "" }
        } catch { phoneError = error.localizedDescription }
    }
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Xcode project or workspace"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "xcodeproj"), UTType(filenameExtension: "xcworkspace")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inspectProject(url.path)
    }
    func inspectProject(_ path: String) {
        inspectionRevision += 1
        let revision = inspectionRevision
        project = path; addError = ""; addedName = ""
        let cached = previews[path] ?? []
        scheme = CodeBuildApp.registrationChoices(cached).first?.project.scheme ?? ""
        branch = cached.first?.branch ?? "main"
        readingSchemes = true
        Task {
            defer { if revision == inspectionRevision { readingSchemes = false } }
            do {
                let rows = try await preview(path)
                guard revision == inspectionRevision else { return }
                previews[path] = rows
                if !rows.contains(where: { $0.project.scheme == scheme }) { scheme = CodeBuildApp.registrationChoices(rows).first?.project.scheme ?? "" }
                branch = rows.first?.branch ?? "main"
                if !detectedProjects.contains(path) { detectedProjects.insert(path, at: 0) }
                savePreviews()
            } catch { if revision == inspectionRevision { addError = error.localizedDescription } }
        }
    }
    func inspectWithXcode() {
        guard !project.isEmpty, !readingSchemes else { return }
        let alert = NSAlert(); alert.messageText = "Read app details with Xcode?"
        alert.informativeText = "This project needs Xcode to read its settings. Xcode can run project code, so only continue with source you trust."
        alert.addButton(withTitle: "Trust and Read"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        inspectionRevision += 1
        let revision = inspectionRevision, path = project
        readingSchemes = true; addError = ""
        Task {
            defer { if revision == inspectionRevision { readingSchemes = false } }
            do {
                let result = try await rpc("project_apps", ["project": path, "trust": true])
                let rows = try JSONDecoder().decode([CodeBuildApp].self, from: JSONSerialization.data(withJSONObject: result))
                guard revision == inspectionRevision else { return }
                previews[path] = rows; scheme = CodeBuildApp.registrationChoices(rows).first?.project.scheme ?? ""
                if rows.isEmpty { addError = "Xcode couldn’t find an iPhone app in this project." }
            } catch { if revision == inspectionRevision { addError = error.localizedDescription } }
        }
    }
    func changeSource(_ source: String) {
        guard !downloading, !inspectingRepository else { return }
        inspectionRevision += 1; readingSchemes = false
        addSource = source; project = ""; scheme = ""; addError = ""
    }
    func pair() { Task { await host?.openPairing(); pairing = (try? await server?.pairingCode()) ?? "" } }
    func search() {
        guard !searching else { return }
        searching = true; addError = ""
        Task {
            defer { searching = false }
            do { results = try await rpc("repo_search", ["query": query]) as? [[String: Any]] ?? [] }
            catch { addError = error.localizedDescription }
        }
    }
    func inspect(_ repository: String) {
        guard !inspectingRepository else { return }
        inspectingRepository = true; inspection = nil; repositoryProjects = []; preparedRepository = nil; project = ""; scheme = ""; addError = ""
        Task {
            defer { inspectingRepository = false }
            do { inspection = try await rpc("repo_inspect", ["repository": repository]) as? [String: Any] }
            catch { addError = error.localizedDescription }
        }
    }
    func downloadRepository() {
        guard let repository = inspection?["repository"] as? String, !downloading else { return }
        let alert = NSAlert(); alert.messageText = "Download this project?"
        alert.informativeText = repository + " will be saved in your projects folder. Only continue with source you trust."
        alert.addButton(withTitle: "Download"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        downloading = true; addError = ""
        Task {
            defer { downloading = false }
            do {
                let info = try await rpc("repo_prepare", ["repository": repository, "trust": true]) as? [String: Any] ?? [:]
                preparedRepository = repository
                repositoryProjects = info["projects"] as? [String] ?? []
                for path in repositoryProjects { previews[path] = try await preview(path) }
                if let first = repositoryProjects.first { inspectProject(first) }
            } catch { addError = error.localizedDescription }
        }
    }
    func add(repository: String? = nil) {
        guard canAdd else { return }
        let alert = NSAlert(); alert.messageText = "Trust this app’s source?"
        alert.informativeText = "Xcode can run scripts from this project on your Mac. Only add source you trust."
        alert.addButton(withTitle: "Trust and Add"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Capture this submission; subsequent UI changes cannot retarget it.
        var params: [String: Any] = ["project": project, "scheme": scheme, "deviceID": phone, "branch": branch, "teamID": team, "enabled": scheduled, "intervalHours": Int(hours) ?? 144, "trust": true, "account": personal ? "free" : "paid"]
        if let repository { params["repository"] = repository }
        else if addSource == "github", let preparedRepository { params["repository"] = preparedRepository }
        adding = true; addError = ""; addedName = ""
        let submittedPhone = phone
        Task {
            defer { adding = false }
            do {
                guard let target = try await rpc(repository == nil ? "target_add" : "repo_add", params) as? [String: Any], let id = target["id"] as? String else {
                    throw NSError(domain: "Orbit", code: 4, userInfo: [NSLocalizedDescriptionKey: "Couldn’t confirm the app was added. Try again."])
                }
                targetRevision += 1
                if let index = targets.firstIndex(where: { $0["id"] as? String == id }) { targets[index] = target }
                else { targets.append(target) }
                UserDefaults.standard.set(submittedPhone, forKey: "Orbit.lastAppPhone")
                addedName = target["name"] as? String ?? "App"
                selectedTab = "apps"
                await refresh()
            } catch { addError = error.localizedDescription }
        }
    }
}
