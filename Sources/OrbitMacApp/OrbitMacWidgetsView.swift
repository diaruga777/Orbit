import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OrbitMacWidgetsView: View {
    @ObservedObject var model: OrbitMacModel
    @State private var scripts: [[String: String]] = []
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Widgets").font(.largeTitle.bold())
                Spacer()
                Button("Add JavaScript", action: add).buttonStyle(.borderedProminent)
            }
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
            Text("On iPhone, open Widgets → Add → From Mac to review each script and its websites. Updating JavaScript doesn’t rebuild the app.").foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
        }.padding(28).task { await reload() }
    }
    private func reload() async { do { scripts = try await model.rpc("widgets") as? [[String: String]] ?? [] } catch { message = error.localizedDescription } }
    private func add() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.javaScript, .plainText]; panel.prompt = "Send to iPhone"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { _ = try await model.rpc("widget_add", ["path": url.path]); message = "Open From Mac in Orbit’s Widgets tab on your iPhone."; await reload() } catch { message = error.localizedDescription } }
    }
}
