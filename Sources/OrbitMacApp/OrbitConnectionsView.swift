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
    @State private var relayReady = false
    @State private var synced = 0
    @State private var phones = 0
    @State private var error = ""
    @State private var statusError = ""

    var body: some View {
        GroupBox("Mac Connection") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Connection", selection: $provider) {
                        Text("Local Wi-Fi").tag("local")
                        Text("Automatic (iroh)").tag("dumbpipe")
                        Text("Tailscale").tag("tailscale")
                        Text("Private Syncthing relay").tag("syncthing")
                    }
                    if provider == "dumbpipe" {
                        Text("Tries local Wi-Fi, Iroh, then Tailscale if available.")
                        TextField("Tailscale fallback (optional)", text: $address, prompt: Text("Auto-detect"))
                        Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                    } else if provider == "tailscale" {
                        Text("Connect both devices to Tailscale, then enter this Mac’s Tailscale IP or MagicDNS name.")
                        Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                        TextField("Tailscale address", text: $address, prompt: Text("your-mac.your-tailnet.ts.net"))
                    } else if provider == "syncthing" {
                        Text("Enter the full relay address, including its certificate ID.")
                        TextField("Relay address", text: $relay, prompt: Text("relay://your-relay:22067/?id=…"))
                    } else {
                        Text("Connect both devices to the same Wi-Fi.")
                    }
                    Button("Apply Connection") { apply() }
                }.disabled(saving || loading)
                if saving || loading {
                    ProgressView(saving ? "Applying connection…" : "Loading connection…").controlSize(.small)
                } else if ready {
                    Label("Selected: \(providerName(activeProvider))", systemImage: "checkmark.circle.fill")
                    if activeProvider == "dumbpipe" {
                        Text(relayReady ? "Iroh discovery is online." : "Connecting to Iroh discovery…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if activeProvider != "local" {
                        Text(phones == 0 ? "Pair a phone to get started." : "\(synced) of \(phones) paired phones updated. Keep Orbit open on your iPhone while it syncs.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if !statusError.isEmpty { Text(statusError).foregroundStyle(.red).textSelection(.enabled) }
                Text("Keep your Mac awake with Orbit running. For installs, authorize your iPhone in More → Mac while connected by cable.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            while !Task.isCancelled {
                if loading {
                    do {
                        let status = try await model.rpc("status") as? [String: Any]
                        let config = status?["configuration"] as? [String: Any] ?? [:]
                        provider = config["provider"] as? String ?? "local"
                        address = config["address"] as? String ?? ""
                        relay = config["relay"] as? String ?? ""
                        loading = false
                    } catch { statusError = error.localizedDescription }
                }
                if !loading { await refresh() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private func providerName(_ provider: String) -> String {
        switch provider {
        case "dumbpipe": "Automatic (iroh)"
        case "tailscale": "Tailscale"
        case "syncthing": "Private Syncthing relay"
        default: "Local Wi-Fi"
        }
    }
    private func refresh() async {
        do {
            let state = try await model.rpc("connection_status") as? [String: Any] ?? [:]
            ready = state["ready"] as? Bool ?? false; activeProvider = state["provider"] as? String ?? "local"
            relayReady = state["irohRelayReady"] as? Bool ?? false
            phones = state["phones"] as? Int ?? 0; synced = state["syncedPhones"] as? Int ?? 0
            statusError = state["error"] as? String ?? ""
        } catch { statusError = error.localizedDescription }
    }
    private func apply() {
        guard !saving else { return }
        saving = true; error = ""
        Task {
            defer { saving = false }
            do {
                _ = try await model.rpc("configure", ["provider": provider, "address": address, "relay": relay])
                await refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
}
