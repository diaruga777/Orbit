import SwiftUI
import AppKit

struct OrbitScriptFolderView: View {
    @ObservedObject var model: OrbitMacModel
    let applets: Bool
    private var path: String { applets ? model.appletFolder : model.widgetFolder }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop .js files here, or save them in this folder.")
                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Show Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.disabled(path.isEmpty)
            Button("Choose Folder…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.canCreateDirectories = true; panel.prompt = "Choose Folder"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                Task { do {
                    _ = try await model.rpc("script_folder", ["kind": applets ? "applet" : "widget", "path": url.path])
                    await model.refreshScripts()
                } catch { model.scriptMessage = error.localizedDescription } }
            }
        }
    }
}
