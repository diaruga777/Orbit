import SwiftUI
import AppKit
import OrbitHost

struct OrbitMacView: View {
    @ObservedObject var model: OrbitMacModel
    @ObservedObject var setup: OrbitSetupModel
    @AppStorage("Orbit.dismissedExtraSetup") private var dismissedExtraSetup = false
    @State private var showExtraSetup = false
    @State private var buildLog: BuildLog?
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
            TabView(selection: $model.selectedTab) {
            OrbitMacAppletsView(model: model).tabItem { Label("Applets", systemImage: "curlybraces.square") }.tag("applets")
            OrbitMacWidgetsView(model: model).tabItem { Label("Widgets", systemImage: "square.grid.2x2") }.tag("widgets")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Orbit Mac").font(.largeTitle.bold())
                    Text(model.status).textSelection(.enabled)
                    HStack { Button("Connect a Phone", action: model.pair); Button("Copy Pairing Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.pairing, forType: .string) }.disabled(model.pairing.isEmpty) }
                    if !model.pairing.isEmpty { Text(model.pairing).font(.caption.monospaced()).textSelection(.enabled) }
                    OrbitMacUpdateView(model: model)
                    Text("Apps").font(.title2)
                    if !model.addedName.isEmpty {
                        HStack {
                            Label("Added \(model.addedName)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Spacer()
                            Button { model.addedName = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
                        }.padding().background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.targets.isEmpty {
                        ContentUnavailableView { Label("No apps yet", systemImage: "apps.iphone") } description: {
                            Text("Add a project to build it for your phone or Mac.")
                        } actions: { Button("Add App") { model.selectedTab = "add" } }
                    }
                    ForEach(Array(model.targets.enumerated()), id: \.offset) { _, app in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                appIcon(app)
                                Text(app["name"] as? String ?? "App").font(.headline)
                                if app["mac"] != nil { Label("This Mac", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(app["failure"] as? String ?? ((app["enabled"] as? Bool == true) ? "Refresh every \(app["intervalHours"] ?? 144) hours" : "Manual refreshes")).font(.callout)
                            if let deployment = app["mac"] as? [String: Any] {
                                Text(deployment["installPath"] as? String ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let job = model.targetJobs[app["id"] as? String ?? ""] {
                                    HStack {
                                        if job["state"] as? String == "running" { ProgressView().controlSize(.small) }
                                        Text(job["stage"] as? String ?? "").font(.callout)
                                        if job["state"] as? String == "running", let id = job["id"] as? String {
                                            Button("Cancel") { Task { do { _ = try await model.rpc("cancel", ["id": id]); await model.refresh() } catch { model.status = error.localizedDescription } } }
                                        }
                                    }
                                }
                            }
                            HStack {
                                Button(app["mac"] != nil ? "Build and Open" : "Build and Install") { Task { do { _ = try await model.rpc("build", ["id": app["id"] ?? ""]); await model.refresh() } catch { model.status = error.localizedDescription } } }
                                Button(app["enabled"] as? Bool == true ? "Pause" : "Enable Refreshes") { Task { do { _ = try await model.rpc("schedule", ["id": app["id"] ?? "", "enabled": !(app["enabled"] as? Bool ?? false)]); await model.refresh() } catch { model.status = error.localizedDescription } } }
                                if let job = (app["jobID"] ?? app["lastJobID"]) as? String {
                                    Button("Show Log") { Task { do {
                                        let result = try await model.rpc("job", ["id": job]) as? [String: Any] ?? [:]
                                        buildLog = BuildLog(id: job, name: app["name"] as? String ?? "App", text: result["log"] as? String ?? "")
                                    } catch { model.status = error.localizedDescription } } }
                                }
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }.tabItem { Label("Apps", systemImage: "apps.iphone") }.tag("apps")
            OrbitAddAppView(model: model, setup: setup).tabItem { Label("Add App", systemImage: "plus") }.tag("add")
            }
        }
        .toolbar { Button("Phone & Remote Setup") { showExtraSetup = true } }
        .sheet(isPresented: $showExtraSetup) { OrbitExtraSetupView(setup: setup, model: model) }
        .sheet(item: $buildLog) { log in
            VStack(alignment: .leading, spacing: 16) {
                Text("\(log.name) build log").font(.title2.bold())
                ScrollView {
                    Text(verbatim: log.text.isEmpty ? "No log output yet." : log.text)
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Done") { buildLog = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 580, height: 400)
        }
    }
    private struct BuildLog: Identifiable {
        let id: String
        let name: String
        let text: String
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
