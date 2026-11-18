import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OrbitMacAppletsView: View {
    @ObservedObject var model: OrbitMacModel
    private var scripts: [[String: String]] { model.applets }
    @State private var message = ""
    @State private var export: AppletExportChoice?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Applets").font(.largeTitle.bold())
                Spacer()
                Button("Copy AI Prompt") { Task { do {
                    let result = try await model.rpc("applet_prompt") as? [String: String] ?? [:]
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result["prompt"] ?? "", forType: .string)
                } catch { message = error.localizedDescription } } }
                Button("Blank Host App") { export = AppletExportChoice(path: nil) }
                Button("Add JavaScript", action: add).buttonStyle(.borderedProminent)
            }
            OrbitScriptFolderView(model: model, applets: true)
            if scripts.isEmpty {
                ContentUnavailableView("No applets yet", systemImage: "curlybraces.square")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(scripts, id: \.["id"]) { script in
                    HStack {
                        Text(script["name"] ?? "Applet").font(.headline)
                        Spacer()
                        Button("Make Standalone App") { export = AppletExportChoice(path: script["id"]) }
                        Button("Remove") { Task { do { _ = try await model.rpc("applet_remove", ["id": script["id"] ?? ""]); await reload() } catch { message = error.localizedDescription } } }
                    }.padding(.vertical, 8)
                }
            }
            Text("Open Orbit on your paired iPhone to review new applets and updates.").font(.callout).foregroundStyle(.secondary)
            if !model.scriptMessage.isEmpty { Text(model.scriptMessage).font(.callout).textSelection(.enabled) }
            if !model.scriptIssues.isEmpty { Text(model.scriptIssues.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if !message.isEmpty { Text(message).textSelection(.enabled) }
        }.padding(28).task { await reload() }
        .sheet(item: $export) { choice in
            OrbitAppletExportSheet(model: model, source: scripts.first { $0["id"] == choice.path }?["source"])
        }
    }
    private func reload() async { await model.refreshScripts() }
    private func add() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.javaScript]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { await model.importScripts(panel.urls) }
    }
}
private struct AppletExportChoice: Identifiable { let id = UUID(); let path: String? }

private struct OrbitAppletExportSheet: View {
    @ObservedObject var model: OrbitMacModel
    let source: String?
    @Environment(\.dismiss) private var dismiss
    @State private var bundleID = ""
    @State private var icon: URL?
    @State private var result: [String: String]?
    @State private var message = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Standalone App").font(.title.bold())
            if let result {
                Text("Your project is ready.")
                Text(result["project"] ?? "").font(.callout).textSelection(.enabled)
                Text("Add it to Apps to build and install with your Xcode account.").foregroundStyle(.secondary)
                HStack {
                    Button("Show Project") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result["project"] ?? "")]) }
                    Button("Add to Apps") {
                        model.project = result["project"] ?? ""; model.scheme = "AppletHost"; model.branch = "main"
                        if model.phone.isEmpty { message = "Choose your phone in Add App, then add this project." }
                        else { model.add(); dismiss() }
                    }.buttonStyle(.borderedProminent)
                    Button("Done") { dismiss() }
                }
            } else {
                TextField("Bundle ID, e.g. com.yourname.myapp", text: $bundleID)
                HStack {
                    if let icon, let image = NSImage(contentsOf: icon) { Image(nsImage: image).resizable().scaledToFit().frame(width: 64, height: 64) }
                    Button(icon?.lastPathComponent ?? "Choose Icon…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]
                        if panel.runModal() == .OK { icon = panel.url }
                    }
                    if icon != nil { Button("Use Default") { icon = nil } }
                }
                Text("A standalone app uses one app slot on your iPhone. Use a square image for its icon.").foregroundStyle(.secondary)
                HStack { Button("Cancel") { dismiss() }; Button("Create Project…", action: create).buttonStyle(.borderedProminent).disabled(bundleID.isEmpty || busy) }
            }
            if busy { ProgressView() }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(28).frame(width: 520)
    }
    private func create() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MyApplet"; panel.canCreateDirectories = true; panel.title = "New Applet Project Folder"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; message = ""
        Task { @MainActor in
            var temporary: URL?
            defer { busy = false; if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            do {
                var params: [String: Any] = ["destination": destination.path, "bundleID": bundleID]
                if let source {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".js"); temporary = url
                    try Data(source.utf8).write(to: url, options: .atomic); params["path"] = url.path
                }
                params["iconPath"] = icon?.path
                result = try await model.rpc("applet_export", params) as? [String: String]
            } catch { message = error.localizedDescription }
        }
    }
}
