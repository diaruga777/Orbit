import SwiftUI
import OrbitHost

struct OrbitExtraSetupView: View {
    @ObservedObject var setup: OrbitSetupModel
    @ObservedObject var model: OrbitMacModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Text("Take Orbit with you").font(.title.bold())
            GroupBox("Refresh without your Mac") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("On iPhone, open More → Phone-only refresh for guided setup.")
                    Text("Connect your iPhone and tap Trust if asked, then export its pairing file.").font(.callout).foregroundStyle(.secondary)
                    Button("Export iPhone Pairing File", action: setup.exportPairing).disabled(setup.state.deviceID.isEmpty || setup.busy)
                    if !setup.message.isEmpty { Text(setup.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("Renew cached builds on Wi-Fi with LocalDevVPN. Building new code still takes a Mac.").font(.callout).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            OrbitConnectionsView(model: model)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28) }.frame(width: 560, height: 480)
    }
}
