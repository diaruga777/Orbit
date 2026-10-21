import SwiftUI
import AppKit
import OrbitHost

struct OrbitSetupView: View {
    @ObservedObject var setup: OrbitSetupModel
    @ObservedObject var model: OrbitMacModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Label("Orbit", systemImage: "sparkles").font(.title2.bold()).padding(.bottom, 12)
                ForEach(OrbitSetupStep.allCases, id: \.self) { step in
                    Label(step.title, systemImage: step.symbol)
                        .font(.callout.weight(step == setup.state.step ? .semibold : .regular))
                        .foregroundStyle(step == setup.state.step ? Color.accentColor : .secondary)
                        .accessibilityAddTraits(step == setup.state.step ? .isSelected : [])
                }
                Spacer()
            }.padding(28).frame(width: 215).background(.ultraThinMaterial)
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: setup.state.step.symbol).font(.system(size: 42, weight: .light)).foregroundStyle(.tint)
                Text(setup.state.step.title).font(.largeTitle.bold())
                ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
                if setup.busy { ProgressView().controlSize(.small) }
                if !setup.message.isEmpty { Text(setup.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    if setup.state.step != .welcome { Button("Back", action: setup.back).disabled(setup.busy) }
                    Spacer()
                    if setup.state.step == .install && setup.busy { Button("Cancel") { setup.cancelInstall(model) } }
                    Button(setup.state.step == .complete ? "Open Orbit" : "Continue", action: setup.next)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!setup.canContinue || setup.busy)
                }
            }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(minWidth: 850, minHeight: 660)
    }
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch setup.state.step {
            case .welcome:
                Text("Your ideas. On your iPhone.").font(.title2.weight(.medium))
                Text("Build apps on your Mac, refresh them on your phone, and make widgets with a little JavaScript.")
                Text("We’ll set up Xcode, connect your iPhone, and install Orbit.").foregroundStyle(.secondary)
                if Bundle.main.bundleURL.path.hasPrefix("/Volumes/") { Button("Install Orbit Mac") { setup.installMac() }.buttonStyle(.borderedProminent) }
            case .tools:
                Text("Orbit uses Xcode to build and sign your iPhone apps.")
                readiness("Full Xcode", ready: setup.tools.xcode)
                readiness("Xcode first-launch setup", ready: setup.tools.firstLaunch)
                readiness("iOS 26 or later SDK", ready: setup.tools.iOSSDK)
                readiness("Command-line runtime", ready: setup.tools.python)
                HStack {
                    Button("Check Again", action: setup.checkTools)
                    if !setup.tools.xcode { Button("Get Xcode") { open("macappstore://itunes.apple.com/app/id497799835") } }
                }
                Button("Install Command Line Tools", action: setup.installTools)
                if setup.tools.xcode && !setup.tools.firstLaunch { Button("Finish Xcode Setup", action: setup.finishXcode) }
                Text("Apple may ask you to sign in, accept the Xcode license, or approve installation. Finish those prompts, then return here.").font(.callout).foregroundStyle(.secondary)
            case .access:
                Text("Choose a folder for your app projects. macOS may ask to allow folder and local-network access.")
                Button(setup.state.folder == nil ? "Choose Projects Folder" : "Change Folder", action: setup.chooseFolder)
                if let folder = setup.state.folder { Text(folder).font(.callout.monospaced()).textSelection(.enabled) }
                Button("Local Network Settings") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") }
                Toggle("Open Orbit when I log in", isOn: Binding(get: { setup.loginItem }, set: { setup.changeLoginItem($0) }))
                Text("Keep your Mac awake and Orbit running while building apps. Phone-only refresh won’t need the Mac after setup.").font(.callout).foregroundStyle(.secondary)
            case .account:
                Text("Sign in to your Apple Account in Xcode → Settings → Accounts. A free Personal Team works for development installs.")
                Button("Open Xcode") { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: setup.tools.developerDirectory).deletingLastPathComponent().deletingLastPathComponent(), configuration: .init()) { _, _ in } }
                TextField("Team ID", text: $setup.state.teamID).textFieldStyle(.roundedBorder).onChange(of: setup.state.teamID) {
                    setup.state.teamID = setup.state.teamID.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if setup.state.bundlePrefix.isEmpty && setup.state.teamID.count == 10 { setup.state.bundlePrefix = "dev.orbit.t" + setup.state.teamID.lowercased() }
                    setup.persist()
                }
                Text("Find your Team ID in Xcode’s account details or your Apple Developer membership page.").font(.callout).foregroundStyle(.secondary)
                TextField("Bundle prefix", text: $setup.state.bundlePrefix).textFieldStyle(.roundedBorder).onChange(of: setup.state.bundlePrefix) { setup.persist() }
                Text("Keep this prefix when updating Orbit so your saved data and Keychain stay available.").font(.callout).foregroundStyle(.secondary)
            case .phone:
                Text("Connect your iPhone by cable, unlock it, and tap Trust if asked.")
                Picker("iPhone", selection: $setup.state.deviceID) {
                    Text("Choose iPhone").tag("")
                    ForEach(setup.devices, id: \.id) { phone in Text(phone.name).tag(phone.id) }
                }.onChange(of: setup.state.deviceID) { setup.phoneReady = false; setup.persist() }
                HStack { Button("Find iPhones") { setup.listPhones(model) }; Button("Check Developer Mode", action: setup.checkPhone).disabled(setup.state.deviceID.isEmpty) }
                GroupBox("Enable Developer Mode") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. On iPhone, open Settings → Privacy & Security → Developer Mode.")
                        Text("2. Turn it on and restart your iPhone.")
                        Text("3. Unlock it, tap Turn On, and enter your passcode.")
                        Text("If Developer Mode isn’t visible, open Xcode → Window → Devices and Simulators and select your connected phone.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            case .agents:
                Text("Connect your AI coding app to Orbit’s local tools.")
                Picker("Integration", selection: $setup.state.agentChoice) { Text("Codex Plugin").tag("codex"); Text("MCP Configuration").tag("mcp"); Text("Set Up Later").tag("later") }
                    .onChange(of: setup.state.agentChoice) { setup.state.agentConfigured = setup.state.agentChoice == "later"; setup.persist() }
                if setup.state.agentChoice != "later" {
                    Button(setup.state.agentChoice == "codex" ? "Show Codex Plugin" : "Export MCP Configuration", action: setup.prepareAgents)
                    Text(setup.state.agentChoice == "codex" ? "Install the Orbit plugin from the folder in Codex’s Plugins settings. Restart or open a new chat if needed." : "Add the exported server entry to your AI app’s MCP settings. It connects to Orbit running on this Mac.").foregroundStyle(.secondary)
                    Toggle("I connected Orbit and tested orbit_status", isOn: $setup.state.agentConfigured).onChange(of: setup.state.agentConfigured) { setup.persist() }
                }
            case .install:
                Text("Orbit will build its iPhone app using your selected team, then install it on your phone.")
                Text("Keep the iPhone unlocked and connected. Xcode may ask you to approve signing in Keychain.").foregroundStyle(.secondary)
                Button(setup.state.installJobID == nil ? "Build and Install Orbit" : "Resume Installation Check") { setup.install(model) }.disabled(setup.busy || setup.state.installed)
                if !setup.log.isEmpty { DisclosureGroup("Installation Log") { ScrollView { Text(setup.log).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 160) } }
                Text("If iPhone asks you to trust the developer, open Settings → General → VPN & Device Management and trust your Apple Account.").font(.callout).foregroundStyle(.secondary)
            case .connect:
                Text("Open Orbit on your iPhone. In Mac → Connect a Mac, paste this pairing code and compare the phone ID before approving it here.")
                HStack { Button("Create Pairing Code", action: model.pair); Button("Copy Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.pairing, forType: .string) }.disabled(model.pairing.isEmpty) }
                if !model.pairing.isEmpty { Text(model.pairing).font(.caption.monospaced()).textSelection(.enabled) }
                Button("Check Connection") { setup.checkConnection(model) }
            case .refresh:
                Text("Finish these steps in Orbit’s Refresh tab on your iPhone:")
                Text("1. Install LocalDevVPN, connect to Wi-Fi, and enable it.")
                Text("2. Import this iPhone’s pairing file from a trusted computer.")
                Text("3. Sign in to your Apple Account, choose your team, and set up a development certificate.")
                Text("4. Choose Cache Orbit, then Check Refresh Connection. Then check setup here.")
                Button("Export This iPhone’s Pairing File", action: setup.exportPairing)
                Link("LocalDevVPN and pairing setup", destination: URL(string: "https://docs.sidestore.io/docs/installation/prerequisites")!)
                Text("Apple passwords, signing keys, and pairing files stay on your phone. Automatic refresh is optional; iOS decides when it can run.").font(.callout).foregroundStyle(.secondary)
                Button("Check Phone Setup") { setup.checkConnection(model) }
            case .complete:
                Text("Orbit is ready.").font(.title2)
                Text("Your Mac builds apps. Your iPhone can renew cached builds without it.")
                Text("Add a JavaScript file in Widgets, or copy the prompt there to make one with your favorite AI app.").foregroundStyle(.secondary)
            }
        }
    }
    private func readiness(_ name: String, ready: Bool) -> some View {
        Label(name, systemImage: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? Color.green : .secondary)
    }
    private func open(_ text: String) { if let url = URL(string: text) { NSWorkspace.shared.open(url) } }
}
