import SwiftUI
import AppKit
import OrbitHost

@main struct OrbitMacApplication: App {
    @StateObject private var model = OrbitMacModel()
    var body: some Scene {
        WindowGroup("Orbit Mac") { OrbitMacView(model: model).frame(minWidth: 660, minHeight: 480) }
        MenuBarExtra("Orbit", systemImage: "sparkles") {
            Button("Open Orbit") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            Button("Quit Orbit") { NSApp.terminate(nil) }
        }
    }
}
@MainActor final class OrbitMacModel: ObservableObject {
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
                try await server.start(); status = "Ready"
                while !Task.isCancelled { await refresh(); try? await Task.sleep(for: .seconds(5)) }
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
struct OrbitMacView: View {
    @ObservedObject var model: OrbitMacModel
    var body: some View {
        TabView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Orbit Mac").font(.largeTitle.bold())
                    Text(model.status).textSelection(.enabled)
                    HStack { Button("Connect a Phone", action: model.pair); Button("Copy Pairing Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.pairing, forType: .string) }.disabled(model.pairing.isEmpty) }
                    if !model.pairing.isEmpty { Text(model.pairing).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("Apps").font(.title2)
                    ForEach(Array(model.targets.enumerated()), id: \.offset) { _, app in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(app["name"] as? String ?? "App").font(.headline)
                            Text(app["failure"] as? String ?? ((app["enabled"] as? Bool == true) ? "Refresh every \(app["intervalHours"] ?? 144) hours" : "Manual refreshes")).font(.callout)
                            HStack {
                                Button("Build and Install") { Task { do { _ = try await model.rpc("build", ["id": app["id"] ?? ""]); await model.refresh() } catch { model.status = error.localizedDescription } } }
                                Button(app["enabled"] as? Bool == true ? "Pause" : "Enable Refreshes") { Task { do { _ = try await model.rpc("schedule", ["id": app["id"] ?? "", "enabled": !(app["enabled"] as? Bool ?? false)]); await model.refresh() } catch { model.status = error.localizedDescription } } }
                                if let job = (app["jobID"] ?? app["lastJobID"]) as? String {
                                    Button("Show Log") { Task { do {
                                        let result = try await model.rpc("job", ["id": job]) as? [String: Any] ?? [:]
                                        let alert = NSAlert(); alert.messageText = result["state"] as? String ?? "Build"
                                        alert.informativeText = result["log"] as? String ?? ""; alert.runModal()
                                    } catch { model.status = error.localizedDescription } } }
                                }
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }.tabItem { Label("Apps", systemImage: "apps.iphone") }
            Form {
                TextField("Project or workspace path", text: $model.project)
                TextField("Scheme", text: $model.scheme)
                TextField("Phone UDID", text: $model.phone)
                TextField("Development team (optional)", text: $model.team)
                TextField("Branch", text: $model.branch)
                Toggle("Free Personal Team", isOn: $model.personal)
                Toggle("Refresh Automatically", isOn: $model.scheduled)
                TextField("Hours between refreshes", text: $model.hours)
                Button("Add Local App") { model.add() }
                Divider()
                HStack { TextField("Search GitHub", text: $model.query).onSubmit(model.search); Button("Search", action: model.search) }
                List(Array(model.results.enumerated()), id: \.offset) { _, result in
                    Button(result["repository"] as? String ?? "Repository") { model.inspect(result["repository"] as? String ?? "") }
                }.frame(minHeight: 140)
                if let info = model.inspection {
                    Text(info["compatible"] as? Bool == true ? "Xcode project found" : "No Xcode project found")
                    ForEach(info["projects"] as? [String] ?? [], id: \.self) { path in
                        Button(path) { model.project = path; model.branch = info["defaultBranch"] as? String ?? "main" }
                    }
                    Button("Clone and Add App") { model.add(repository: info["repository"] as? String) }.disabled(info["compatible"] as? Bool != true)
                }
            }.padding().tabItem { Label("Add App", systemImage: "plus") }
        }
    }
}
