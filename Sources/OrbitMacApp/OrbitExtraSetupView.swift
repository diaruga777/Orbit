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
                    Text("Open More → Phone-only refresh in Orbit on your iPhone. Set up your Apple Account, certificate and pairing file, then cache Orbit. Enable LocalDevVPN while on Wi-Fi.")
                    Text("To export the pairing file, your iPhone needs to have trusted this Mac. You don’t need to sign in on iPhone or turn on LocalDevVPN first.").font(.callout).foregroundStyle(.secondary)
                    Button("Export iPhone Pairing File", action: setup.exportPairing).disabled(setup.state.deviceID.isEmpty || setup.busy)
                    if !setup.message.isEmpty { Text(setup.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("Your phone can renew cached builds. New code still needs your Mac, and iOS controls background refresh.").font(.callout).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            OrbitConnectionsView(model: model)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28) }.frame(width: 610, height: 690)
    }
}
