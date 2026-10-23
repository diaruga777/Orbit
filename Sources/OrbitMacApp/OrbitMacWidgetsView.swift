import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OrbitMacWidgetsView: View {
    @ObservedObject var model: OrbitMacModel
    private var scripts: [[String: String]] { model.widgets }
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Widgets").font(.largeTitle.bold())
                Spacer()
                Button("Add JavaScript", action: add).buttonStyle(.borderedProminent)
            }
            OrbitScriptFolderView(model: model, applets: false)
            if scripts.isEmpty { ContentUnavailableView("Make It Yours", systemImage: "square.grid.2x2", description: Text("Add a JavaScript widget, then approve it in Orbit on your iPhone.")) }
            else {
                List(Array(scripts.enumerated()), id: \.offset) { _, script in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) { Text(script["name"] ?? "Widget").font(.headline); Text("Ready for your iPhone").foregroundStyle(.secondary) }
                        Spacer()
                        Button("Remove") { Task { do { _ = try await model.rpc("widget_remove", ["id": script["id"] ?? ""]); await reload() } catch { message = error.localizedDescription } } }
                    }.padding(.vertical, 8)
                }
            }
            Text("Files sync when Orbit is open on your connected iPhone. Review new files and updates in Widgets. Updating JavaScript doesn’t rebuild the app.").foregroundStyle(.secondary)
            if !model.scriptMessage.isEmpty { Text(model.scriptMessage).font(.callout).textSelection(.enabled) }
            if !model.scriptIssues.isEmpty { Text(model.scriptIssues.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
        }.padding(28).task { await reload() }
    }
    private func reload() async { await model.refreshScripts() }
    private func add() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.javaScript]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { await model.importScripts(panel.urls) }
    }
}
