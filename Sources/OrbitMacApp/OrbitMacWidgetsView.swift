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
            if scripts.isEmpty {
                ContentUnavailableView("No widgets yet", systemImage: "square.grid.2x2")
            } else {
                List(scripts, id: \.["id"]) { script in
                    HStack {
                        Text(script["name"] ?? "Widget").font(.headline)
                        Spacer()
                        Button("Remove") { Task { do { _ = try await model.rpc("widget_remove", ["id": script["id"] ?? ""]); await reload() } catch { message = error.localizedDescription } } }
                    }.padding(.vertical, 8)
                }
            }
            Text("Open Orbit on your paired iPhone to review new widgets and updates.").font(.callout).foregroundStyle(.secondary)
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
