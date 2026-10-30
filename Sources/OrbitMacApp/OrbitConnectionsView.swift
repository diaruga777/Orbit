import SwiftUI

struct OrbitConnectionsView: View {
    @ObservedObject var model: OrbitMacModel
    @State private var provider = "local"
    @State private var address = ""
    @State private var relay = ""
    @State private var saving = false
    @State private var loading = true
    @State private var ready = false
    @State private var activeProvider = "local"
    @State private var synced = 0
    @State private var phones = 0
    @State private var error = ""
    @State private var message = ""

    var body: some View {
        GroupBox("Build away from home") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enable remote connections to reach your Mac from another network. Your paired iPhone updates automatically while Orbit is open and connected.")
                Label(ready ? (activeProvider == "local" ? "Local Wi-Fi is ready" : "Remote connections are enabled") : "Connections aren’t ready",
                      systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(ready ? Color.green : Color.secondary)
                if activeProvider != "local", ready {
                    Text(phones == 0 ? "Connect a phone to get started." : "\(synced) of \(phones) paired phones updated. Open Orbit on the same Wi-Fi before leaving home.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if activeProvider == "local" {
                    Button("Enable Remote Connections") { provider = "dumbpipe"; apply() }
                        .disabled(saving || loading)
                }
                DisclosureGroup("Connection options") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Connection", selection: $provider) {
                            Text("Local Wi-Fi").tag("local")
                            Text("Automatic (iroh)").tag("dumbpipe")
                            Text("Tailscale").tag("tailscale")
                            Text("Private Syncthing relay").tag("syncthing")
                        }
                        if provider == "dumbpipe" {
                            Text("Uses iroh’s discovery and public relays when needed. No extra account or software.")
                        } else if provider == "tailscale" {
                            Text("Connect Tailscale on both devices, then enter this Mac’s Tailscale address.")
                            Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                            TextField("tcp://your-mac.your-tailnet.ts.net:49210", text: $address)
                        } else if provider == "syncthing" {
                            Text("Use a relay you run or trust. Paste its full address, including the certificate ID. Folder sync alone won’t work.")
                            TextField("relay://your-relay:22067/?id=…", text: $relay)
                        } else {
                            Text("Connect on the same Wi-Fi. Public discovery and relays are off.")
                        }
                        Button("Apply Connection") { apply() }
                    }.padding(.top, 8).disabled(saving || loading)
                }
                if saving { ProgressView("Setting up connections…").controlSize(.small) }
                if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if !message.isEmpty { Text(message).textSelection(.enabled) }
                Text("Keep your Mac awake with Orbit running. For installs, authorize this phone in its Mac tab while connected by cable first.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            do {
                let status = try await model.rpc("status") as? [String: Any]
                let config = status?["configuration"] as? [String: Any] ?? [:]
                provider = config["provider"] as? String ?? "local"
                address = config["address"] as? String ?? ""; relay = config["relay"] as? String ?? ""
            } catch { self.error = error.localizedDescription }
            loading = false
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private func refresh() async {
        do {
            let state = try await model.rpc("connection_status") as? [String: Any] ?? [:]
            ready = state["ready"] as? Bool ?? false; activeProvider = state["provider"] as? String ?? "local"
            phones = state["phones"] as? Int ?? 0; synced = state["syncedPhones"] as? Int ?? 0
            if let failure = state["error"] as? String, !failure.isEmpty { error = failure }
        } catch { self.error = error.localizedDescription }
    }
    private func apply() {
        guard !saving else { return }
        saving = true; error = ""; message = ""
        Task {
            defer { saving = false }
            do {
                _ = try await model.rpc("configure", ["provider": provider, "address": address, "relay": relay])
                message = provider == "local" ? "Local Wi-Fi enabled." : "Remote connections enabled. No restart or new code needed."
                await refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
}
