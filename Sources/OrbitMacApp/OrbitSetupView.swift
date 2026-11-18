import SwiftUI
import AppKit
import OrbitHost

struct OrbitSetupView: View {
    @ObservedObject var setup: OrbitSetupModel
    @ObservedObject var model: OrbitMacModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Text("Orbit").font(.title2.bold()).padding(.bottom, 12)
                ForEach(OrbitSetupStep.allCases, id: \.self) { step in
                    Label(step.title, systemImage: step.symbol)
                        .font(.callout.weight(step == setup.state.step ? .semibold : .regular))
                        .foregroundStyle(step == setup.state.step ? Color.accentColor : .secondary)
                        .accessibilityAddTraits(step == setup.state.step ? .isSelected : [])
                }
                Spacer()
            }.padding(28).frame(width: 215).background(.ultraThinMaterial)
            VStack(alignment: .leading, spacing: 22) {
                Text(setup.state.step.title).font(.largeTitle.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        content
                        if setup.busy { ProgressView().controlSize(.small) }
                        if !setup.message.isEmpty {
                            Text(setup.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.id(setup.state.step)
                HStack {
                    if setup.state.step != .welcome { Button("Back", action: setup.back).disabled(setup.busy) }
                    Spacer()
                    if setup.state.step == .phone && setup.busy { Button("Cancel") { setup.cancelInstall(model) } }
                    if setup.state.step == .access && setup.state.folderApproved != true {
                        Button("Use This Folder") { setup.allowFolder(model) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(setup.busy)
                    } else {
                        Button(setup.state.step == .complete ? "Open Orbit" : "Continue", action: setup.next)
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!setup.canContinue || setup.busy)
                    }
                }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(minWidth: 760, minHeight: 540)
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
                Text("To install Orbit, you’ll need your Apple Account and a cable for your iPhone.")
                Text("Connect your Mac and iPhone to the same Wi-Fi.").foregroundStyle(.secondary)
                if Bundle.main.bundleURL.path.hasPrefix("/Volumes/") { Button("Install Orbit Mac") { setup.installMac() }.buttonStyle(.borderedProminent) }
            case .tools:
                readiness("Xcode", ready: setup.tools.xcode)
                readiness("Xcode setup", ready: setup.tools.firstLaunch)
                readiness("iPhone build tools", ready: setup.tools.iOSSDK)
                readiness("Local tools", ready: setup.tools.python)
                if !setup.tools.ready {
                    OrbitToolInstallerView(installer: setup.installer, install: setup.installTools, check: setup.checkTools)
                }
            case .access:
                Text("Choose where Orbit looks for your projects.")
                if let folder = setup.state.folder { Text(folder).font(.callout.monospaced()).textSelection(.enabled) }
                Button("Choose Folder…") { setup.chooseFolder() }.disabled(setup.busy)
                Text("Allow folder and local network access if macOS asks.").font(.callout).foregroundStyle(.secondary)
                Button("Local Network Settings") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") }
                Toggle("Open Orbit when I log in", isOn: Binding(get: { setup.loginItem }, set: { setup.changeLoginItem($0) }))
                Text("Keep your Mac awake and Orbit open for scheduled builds.").font(.callout).foregroundStyle(.secondary)
            case .account:
                Text("A free Apple Account works for installing Orbit.")
                if setup.teams.isEmpty {
                    Text("Add your account in Xcode → Settings → Accounts, then return here.").foregroundStyle(.secondary)
                } else {
                    Picker("Signing team", selection: $setup.state.teamID) {
                        Text("Choose a team").tag("")
                        ForEach(setup.teams) { team in Text(team.name).tag(team.id) }
                        if !setup.state.teamID.isEmpty && !setup.teams.contains(where: { $0.id == setup.state.teamID }) {
                            Text("Previously selected team").tag(setup.state.teamID)
                        }
                    }.disabled(setup.state.installed || setup.state.installJobID != nil).onChange(of: setup.state.teamID) { setup.persist() }
                }
                HStack { Button("Open Xcode", action: setup.openXcode); Button("Check Account", action: setup.checkAccounts) }
                Text("Xcode keeps your signing keys in your Mac’s Keychain.").font(.callout).foregroundStyle(.secondary)
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
                    DisclosureGroup("Developer Mode and trust settings") {
                        Text("If Developer Mode is missing, open Xcode → Window → Devices and Simulators. To trust your developer account on iPhone, open Settings → General → VPN & Device Management.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Orbit is installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Open Orbit on your iPhone. In More → Mac → Connect a Mac, paste this code. Compare the phone ID before approving here.")
                    HStack {
                        Button(model.pairing.isEmpty ? "Create Connection Code" : "New Code", action: model.pair)
                        Button("Copy Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.pairing, forType: .string) }.disabled(model.pairing.isEmpty)
                        Button("Check Connection") { setup.checkConnection(model) }
                    }
                    if !model.pairing.isEmpty { Text(model.pairing).font(.caption.monospaced()).textSelection(.enabled) }
                    if setup.paired { Label("Your iPhone is connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    if !setup.paired { Text("You can connect later in More → Mac.").font(.callout).foregroundStyle(.secondary) }

                }
                if !setup.log.isEmpty { DisclosureGroup("Installation Log") { ScrollView { Text(setup.log).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 150) } }
            case .agents, .install, .connect, .refresh:
                EmptyView() // Migrated to the current steps when loading saved setup.
            case .complete:
                Text("Choose Add App to build your first Xcode project, or drop a .js file into Orbit for an applet or widget.")
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
