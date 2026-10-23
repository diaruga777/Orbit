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
                    if setup.state.step == .phone && setup.busy { Button("Cancel") { setup.cancelInstall(model) } }
                    Button(setup.state.step == .complete ? "Open Orbit" : "Continue", action: setup.next)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!setup.canContinue || setup.busy)
                }
            }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(minWidth: 850, minHeight: 660)
        .task(id: setup.state.step) {
            if setup.state.step == .phone && !setup.state.installed { setup.listPhones(model) }
            if setup.state.step == .account { setup.checkAccounts() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if setup.state.step == .account { setup.checkAccounts() }
        }
    }
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch setup.state.step {
            case .welcome:
                Text("Your ideas. On your iPhone.").font(.title2.weight(.medium))
                Text("Build apps on your Mac and make widgets for your iPhone.")
                Text("We’ll set up your Mac and install Orbit on your iPhone. Keep both on the same Wi-Fi to get started.").foregroundStyle(.secondary)
                if Bundle.main.bundleURL.path.hasPrefix("/Volumes/") { Button("Install Orbit Mac") { setup.installMac() }.buttonStyle(.borderedProminent) }
            case .tools:
                Text("Orbit will install Xcode and the tools it needs for you.")
                readiness("Xcode", ready: setup.tools.xcode)
                readiness("Xcode setup", ready: setup.tools.firstLaunch)
                readiness("iPhone build tools", ready: setup.tools.iOSSDK)
                readiness("Local tools", ready: setup.tools.python)
                OrbitToolInstallerView(installer: setup.installer, install: setup.installTools, check: setup.checkTools)
                Text("Apple may ask for your account, a verification code, or your Mac password. Reply below when asked. Downloads can take a while.").font(.callout).foregroundStyle(.secondary)
            case .access:
                Text("Your apps will live here. You can choose another folder anytime.")
                if let folder = setup.state.folder { Text(folder).font(.callout.monospaced()).textSelection(.enabled) }
                HStack {
                    Button("Use This Folder") { setup.allowFolder(model) }
                    Button("Choose Another Folder") { setup.chooseFolder(model) }
                }
                Text("Allow folder and local-network access if macOS asks. Orbit’s local tools start whenever Orbit is open; there’s no separate AI setup.").font(.callout).foregroundStyle(.secondary)
                Button("Local Network Settings") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") }
                Toggle("Open Orbit when I log in", isOn: Binding(get: { setup.loginItem }, set: { setup.changeLoginItem($0) }))
                Text("Keep your Mac awake and Orbit running while building apps. Phone-only refresh won’t need the Mac after setup.").font(.callout).foregroundStyle(.secondary)
            case .account:
                Text("Use your Apple Account to put Orbit on your iPhone. A free account works.")
                if setup.teams.isEmpty {
                    Text("Add your account in Xcode → Settings → Accounts. Then come back here; Orbit will find it.").foregroundStyle(.secondary)
                } else {
                    Picker("Apple Account", selection: $setup.state.teamID) {
                        Text("Choose Account").tag("")
                        ForEach(setup.teams) { team in Text(team.name).tag(team.id) }
                        if !setup.state.teamID.isEmpty && !setup.teams.contains(where: { $0.id == setup.state.teamID }) {
                            Text("Previously Selected Account").tag(setup.state.teamID)
                        }
                    }.disabled(setup.state.installed || setup.state.installJobID != nil).onChange(of: setup.state.teamID) { setup.persist() }
                }
                HStack { Button("Open Xcode", action: setup.openXcode); Button("Check Account", action: setup.checkAccounts) }
                Text("Orbit handles the app’s identifiers. Xcode keeps your signing account and keys in your Mac’s Keychain.").font(.callout).foregroundStyle(.secondary)
            case .phone:
                if !setup.state.installed {
                    Text("Connect your iPhone by cable, unlock it, and tap Trust if asked.")
                    Picker("iPhone", selection: $setup.state.deviceID) {
                        Text("Choose iPhone").tag("")
                        ForEach(setup.devices, id: \.id) { phone in Text(phone.name).tag(phone.id) }
                        if !setup.state.deviceID.isEmpty && !setup.devices.contains(where: { $0.id == setup.state.deviceID }) {
                            Text("Selected iPhone (Reconnect to Continue)").tag(setup.state.deviceID)
                        }
                    }.disabled(setup.busy || setup.state.installJobID != nil)
                        .onChange(of: setup.state.deviceID) { setup.phoneReady = false; setup.persist() }
                    Button("Find iPhones") { setup.listPhones(model) }.disabled(setup.busy)
                    Text("On iPhone, turn on Settings → Privacy & Security → Developer Mode, restart, and tap Turn On. Keep it unlocked for installation.").font(.callout).foregroundStyle(.secondary)
                    Button(setup.state.installJobID == nil ? "Install Orbit on iPhone" : "Resume Installation") { setup.install(model) }
                        .buttonStyle(.borderedProminent).disabled(setup.busy || setup.state.deviceID.isEmpty)
                    Text("If Developer Mode is missing, open Xcode → Window → Devices and Simulators. If asked to trust your developer account, use Settings → General → VPN & Device Management on iPhone.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Label("Orbit is installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Open Orbit on your iPhone. In Mac → Connect a Mac, paste this code. Compare the phone ID before approving here.")
                    HStack {
                        Button(model.pairing.isEmpty ? "Create Connection Code" : "New Code", action: model.pair)
                        Button("Copy Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.pairing, forType: .string) }.disabled(model.pairing.isEmpty)
                        Button("Check Connection") { setup.checkConnection(model) }
                    }
                    if !model.pairing.isEmpty { Text(model.pairing).font(.caption.monospaced()).textSelection(.enabled) }
                    if setup.paired { Label("Your iPhone is connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Text("You can also connect later from Orbit’s Mac tab.").font(.callout).foregroundStyle(.secondary)

                }
                if !setup.log.isEmpty { DisclosureGroup("Installation Log") { ScrollView { Text(setup.log).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 150) } }
            case .agents, .install, .connect, .refresh:
                EmptyView() // Migrated to the current steps when loading saved setup.
            case .complete:
                Text("Orbit is ready.").font(.title2)
                Text("Your Mac is ready to build apps. You can set up phone-only refresh later in Orbit’s Refresh tab.")
                Text("Add a JavaScript file in Widgets, or copy the prompt there to make one with your favorite AI app.").foregroundStyle(.secondary)
            }
        }
    }
    private func readiness(_ name: String, ready: Bool) -> some View {
        Label(name, systemImage: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? Color.green : .secondary)
    }
    private func open(_ text: String) { if let url = URL(string: text) { NSWorkspace.shared.open(url) } }
}

private struct OrbitToolInstallerView: View {
    @ObservedObject var installer: OrbitToolInstaller
    var install: () -> Void
    var check: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Install Mac Tools", action: install).disabled(installer.running)
                Button("Check Again", action: check).disabled(installer.running)
                if installer.running { ProgressView().controlSize(.small); Button("Cancel", action: installer.cancel) }
            }
            if !installer.output.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(installer.output).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }.frame(height: 140).onChange(of: installer.output) { proxy.scrollTo("end") }
                }
            }
            if installer.running {
                HStack {
                    SecureField("Reply to the installer’s prompt", text: $installer.response).onSubmit(installer.send)
                    Button("Send", action: installer.send)
                }
                Text("Press Send with an empty reply to accept a default. Replies aren’t saved in Orbit’s logs.").font(.caption).foregroundStyle(.secondary)
            }
        }.onChange(of: installer.running) { if !installer.running { check() } }
    }
}
