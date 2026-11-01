import SwiftUI

struct OrbitMacUpdateView: View {
    @ObservedObject var model: OrbitMacModel
    @State private var showingLog = false
    private var busy: Bool { ["accepted", "building", "installing", "restarting", "installed"].contains(model.macUpdate["state"] as? String ?? "") || model.startingMacUpdate }
    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "desktopcomputer").font(.title2)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Orbit Mac").font(.headline)
                    Text(model.macUpdate["failure"] as? String ?? model.macUpdate["stage"] as? String ?? "Checking for updates…")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if let revision = model.macUpdate["runningRevision"] as? String, !revision.isEmpty {
                        Text("Running \(revision.prefix(8))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(busy ? "Updating…" : "Rebuild Orbit Mac") { model.rebuildMac() }
                            .disabled(busy || model.macUpdate["available"] as? Bool != true)
                            .accessibilityIdentifier("OrbitMacRebuild")
                        if model.macUpdate["log"] as? String != nil { Button("Show Log") { showingLog = true } }
                        if busy { ProgressView().controlSize(.small) }
                    }
                }
                Spacer()
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingLog) {
            VStack(alignment: .leading) {
                Text("Orbit Mac Update").font(.headline)
                ScrollView { Text(model.macUpdate["log"] as? String ?? "No log yet.").font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Done") { showingLog = false }.keyboardShortcut(.defaultAction)
            }.padding().frame(width: 720, height: 480)
        }
    }
}
