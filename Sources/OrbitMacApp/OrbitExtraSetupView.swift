import SwiftUI
import OrbitHost

struct OrbitExtraSetupView: View {
    @ObservedObject var setup: OrbitSetupModel
    @ObservedObject var model: OrbitMacModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Take Orbit with you").font(.title.bold())
            GroupBox("Refresh without your Mac") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Open Refresh in Orbit on your iPhone. Set up your Apple Account, certificate and pairing file, then cache Orbit. Enable LocalDevVPN while on Wi-Fi.")
                    Button("Export iPhone Pairing File", action: setup.exportPairing).disabled(setup.state.deviceID.isEmpty || setup.busy)
                    if !setup.message.isEmpty { Text(setup.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("Your phone can renew cached builds. New code still needs your Mac, and iOS controls background refresh.").font(.callout).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Build away from home") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Same Wi-Fi is the default. Enable internet connections to reach your Mac from another network using iroh’s discovery and relays.")
                    Button("Enable Remote Connections") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                _ = try await model.rpc("configure", ["provider": "dumbpipe"])
                                message = "Quit and reopen Orbit Mac. Then create a new connection code and use it in your iPhone’s Mac tab. Compare the phone ID before approving."
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(saving)
                    Text("Your Mac must stay awake with Orbit running. For installs, authorize this phone in its Mac tab while connected by cable first. A remote connection alone doesn’t make Apple installation available.").font(.callout).foregroundStyle(.secondary)
                    Link("More connection options", destination: URL(string: "https://github.com/diaruga777/Orbit/blob/main/docs/pipes.md")!)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 610)
    }
}
