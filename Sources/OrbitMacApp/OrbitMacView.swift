import SwiftUI
import AppKit
import OrbitHost

struct OrbitMacView: View {
    @ObservedObject var model: OrbitMacModel
    @ObservedObject var setup: OrbitSetupModel
    @AppStorage("Orbit.dismissedExtraSetup") private var dismissedExtraSetup = false
    @State private var showExtraSetup = false
    var body: some View {
        VStack(spacing: 0) {
            if !dismissedExtraSetup {
                HStack(spacing: 14) {
                    Image(systemName: "iphone.radiowaves.left.and.right").font(.title2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Take Orbit with you").font(.headline)
                        Text("Refresh without your Mac, or build away from home.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Set Up") { showExtraSetup = true }.buttonStyle(.borderedProminent)
                    Button { dismissedExtraSetup = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
                }.padding().background(.thinMaterial)
            }
            TabView {
            OrbitMacAppletsView(model: model).tabItem { Label("Applets", systemImage: "curlybraces.square") }
            OrbitMacWidgetsView(model: model).tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Orbit Mac").font(.largeTitle.bold())
                    Text(model.status).textSelection(.enabled)
                    HStack { Button("Connect a Phone", action: model.pair); Button("Copy Pairing Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.pairing, forType: .string) }.disabled(model.pairing.isEmpty) }
                    if !model.pairing.isEmpty { Text(model.pairing).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("Apps").font(.title2)
                    ForEach(Array(model.targets.enumerated()), id: \.offset) { _, app in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                appIcon(app)
                                Text(app["name"] as? String ?? "App").font(.headline)
                            }
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
        .toolbar { Button("Phone & Remote Setup") { showExtraSetup = true } }
        .sheet(isPresented: $showExtraSetup) { OrbitExtraSetupView(setup: setup, model: model) }
    }
    private func appIcon(_ app: [String: Any]) -> some View {
        Group {
            if let encoded = app["iconPNG"] as? String, let data = Data(base64Encoded: encoded), let icon = NSImage(data: data) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary).padding(6)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}
