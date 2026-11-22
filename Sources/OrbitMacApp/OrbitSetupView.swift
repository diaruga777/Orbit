import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
import OrbitHost

struct OrbitSetupView: View {
    @ObservedObject var setup: OrbitSetupModel
    @ObservedObject var model: OrbitMacModel

    @State private var discoveryRevision = 0

    private var onMac: Bool { setup.fromDiskImage || setup.state.step.current == .mac }
    private var deviceKind: String {
        guard let device = setup.selectedDevice else { return "device" }
        return device.isPad ? "iPad" : "iPhone"
    }
    private var title: String {
        if setup.fromDiskImage { return "Install Orbit Mac" }
        if onMac { return "Set up your Mac" }
        if setup.state.installed { return "Orbit is installed" }
        return "Install Orbit"
    }
    private var hardware: Image {
        if onMac, let image = NSImage(named: NSImage.computerName) { return Image(nsImage: image) }
        if let modelCode = setup.selectedDevice?.modelCode,
           let type = UTType.types(tag: modelCode, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil).first(where: { $0.isDeclared }) {
            return Image(nsImage: NSWorkspace.shared.icon(for: type))
        }
        if onMac { return Image(systemName: "desktopcomputer") }
        guard let device = setup.selectedDevice else { return Image(systemName: "ipad.and.iphone") }
        return Image(systemName: device.isPad ? "ipad" : "iphone")
    }
    private var deviceCaption: String {
        if onMac {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        }
        guard let device = setup.selectedDevice else { return "iPhone or iPad" }
        return [device.modelName ?? device.name, device.systemVersion.map { "\(device.systemName) \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        hardware.resizable().scaledToFit().frame(width: 72, height: 72).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.largeTitle.bold())
                            Text(deviceCaption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    if setup.fromDiskImage {
                        guide("folder", "Install in your Applications folder.")
                    } else if onMac { mac } else { phone }
                    if setup.busy && !setup.installing { ProgressView().controlSize(.small).accessibilityLabel("Checking setup") }
                    if !setup.message.isEmpty { Text(setup.message).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(32).frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                if !onMac && !setup.installing { Button("Mac setup", action: setup.back).disabled(setup.busy) }
                Spacer()
                if setup.fromDiskImage { primary("Install Orbit Mac", setup.installMac) }
                else if onMac && setup.tools.ready && setup.signingReady {
                    primary(setup.state.folderApproved == true ? "Continue" : "Use This Folder") { setup.allowFolder(model) }
                } else if !onMac {
                    if setup.state.installed { primary("Done", setup.finish) }
                    else if setup.installing { Button("Cancel Installation") { setup.cancelInstall(model) } }
                    else if setup.state.installJobID != nil { primary("Resume Installation") { setup.install(model) } }
                    else if let device = setup.selectedDevice, !device.needsSystemUpdate {
                        primary("Install Orbit") { setup.install(model) }
                    }
                }
            }.padding(.horizontal, 28).padding(.vertical, 16)
        }.frame(minWidth: 760, minHeight: 540)
        .task(id: onMac ? nil : discoveryRevision) {
            guard !onMac else { return }
            repeat {
                await setup.listPhones(model)
                if setup.selectedDevice != nil || setup.state.installed || setup.state.installJobID != nil { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
        .task(id: setup.state.deviceID) {
            setup.phoneReady = nil
            await setup.checkSelectedDevice()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if onMac && !setup.fromDiskImage && setup.tools.ready && !setup.installer.running { setup.checkAccounts() }
        }
    }

    @ViewBuilder private var mac: some View {
        if !setup.tools.ready {
            guide("hammer", setup.tools.xcode ? "Finish installing the Mac build tools." : "Install Xcode to build Orbit.")
            OrbitToolInstallerView(installer: setup.installer, install: setup.installTools, check: setup.checkTools)
        } else if setup.teams.isEmpty && !setup.signingReady {
            Text("Add your Apple Account in Xcode.").font(.headline)
            guide("gearshape", "Settings", destination: "Accounts")
            Button("Open Xcode", action: setup.openXcode).buttonStyle(.borderedProminent)
            Button("Check Again", action: setup.checkAccounts).disabled(setup.busy)
        } else {
            if setup.teams.count > 1 || !setup.signingReady {
                Picker("Signing team", selection: $setup.state.teamID) {
                    Text("Choose a team").tag("")
                    ForEach(setup.teams) { Text($0.name).tag($0.id) }
                    if !setup.state.teamID.isEmpty && !setup.teams.contains(where: { $0.id == setup.state.teamID }) {
                        Text("Saved team").tag(setup.state.teamID)
                    }
                }.disabled(setup.busy || setup.state.installed || setup.state.installJobID != nil)
                    .onChange(of: setup.state.teamID) { setup.persist() }
            }
            Text("Projects folder").font(.headline)
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 38, height: 38).accessibilityHidden(true)
                Text(((setup.state.folder ?? OrbitSetupState.defaultFolder.path) as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Change…") { setup.chooseFolder(model) }.disabled(setup.busy)
            }
            DisclosureGroup("Mac options") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Open Orbit at login", isOn: Binding(get: { setup.loginItem }, set: setup.changeLoginItem))
                    Link("Local Network Settings", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    @ViewBuilder private var phone: some View {
        if setup.state.installed {
            if !model.pairing.isEmpty {
                HStack(alignment: .center, spacing: 18) {
                    if let image = Self.qrCode(model.pairing) {
                        Image(decorative: image, scale: 1).interpolation(.none).resizable().frame(width: 144, height: 144)
                            .padding(12).background(.white).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Connect with Camera", systemImage: "qrcode.viewfinder").font(.headline)
                        Text("Use the same Wi-Fi. Compare the device ID before approving on your Mac.")
                        Button("Copy Code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.pairing, forType: .string)
                        }
                    }
                }
            }
            if !model.pairing.isEmpty {
                DisclosureGroup("Paste a code instead") {
                    guide("ellipsis.circle", "Orbit › More › Mac", destination: "Connect a Mac")
                }
            }
            DisclosureGroup("Orbit won’t open?") {
                settingsPath(section: "General", icon: "gearshape", item: "VPN & Device Management", toggle: false)
                guide("checkmark.shield", "Select and trust your developer account.")
            }
            Button(model.pairing.isEmpty ? "Connect to This Mac" : "Renew Code", action: model.pair)
        } else if setup.installing {
            ProgressView("Keep your device connected.")
        } else {
            if setup.devices.count > 1 || !setup.state.deviceID.isEmpty && setup.selectedDevice == nil {
                Picker("Device", selection: $setup.state.deviceID) {
                    Text("Choose a device").tag("")
                    ForEach(setup.devices, id: \.id) { Text($0.name).tag($0.id) }
                    if !setup.state.deviceID.isEmpty && setup.selectedDevice == nil {
                        Text("Saved device · offline").tag(setup.state.deviceID)
                    }
                }.disabled(setup.busy || setup.state.installJobID != nil)
                    .onChange(of: setup.state.deviceID) { setup.persist() }
            }
            if setup.state.installJobID != nil { guide("arrow.clockwise", "Pick up your installation.") }
            else if let device = setup.selectedDevice {
                if device.needsSystemUpdate {
                    Text("Orbit needs \(device.systemName) 26 or later.").font(.headline)
                    settingsPath(section: "General", icon: "gearshape", item: "Software Update", toggle: false)
                } else if setup.phoneReady == false { developerMode }
                else { guide("lock.open", "Keep your \(deviceKind) unlocked.") }
            } else if setup.devices.isEmpty || !setup.state.deviceID.isEmpty {
                guide("cable.connector", "Connect by cable and unlock your device.")
                guide("hand.raised", "Tap Trust if asked.")
                DisclosureGroup("Device missing?") { developerMode }
            }
            Button("Find Devices") { discoveryRevision += 1 }.disabled(setup.busy)
        }
        if !setup.log.isEmpty {
            DisclosureGroup("Installation log") {
                Text(setup.log).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    private var developerMode: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsPath(section: "Privacy & Security", icon: "hand.raised.fill", item: "Developer Mode", toggle: true)
            guide("restart", "Turn it on, restart, then confirm.")
            if setup.tools.xcode {
                let app = URL(fileURLWithPath: setup.tools.developerDirectory).deletingLastPathComponent().deletingLastPathComponent()
                let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                let modern = (Int(version?.split(separator: ".").first ?? "") ?? 0) >= 27
                Text(modern ? "Missing the switch? In Xcode, open Developer Tool › Device Hub to pair first." : "Missing the switch? In Xcode, open Window › Devices and Simulators to pair first.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    // Show the settings hierarchy side by side on iPad and stacked on iPhone.
    private func settingsPath(section: String, icon: String, item: String, toggle: Bool) -> some View {
        let layout = setup.selectedDevice?.isPad == true
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return layout {
            VStack(alignment: .leading, spacing: 8) {
                Text("Settings").font(.headline)
                Label(section, systemImage: icon).foregroundStyle(.tint)
            }
            Divider()
            HStack {
                Text(item).fontWeight(.medium)
                Spacer()
                if toggle {
                    Image(systemName: "switch.2").foregroundStyle(.green)
                } else { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
            }
        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Settings, \(section), \(item)")
    }
    private func guide(_ symbol: String, _ text: String, destination: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24).accessibilityHidden(true)
            Text(text)
            if let destination {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(destination).fontWeight(.medium)
            }
        }.accessibilityElement(children: .combine)
    }
    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(setup.busy)
    }
    private static func qrCode(_ code: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        guard let image = filter.outputImage else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }
}
private struct OrbitToolInstallerView: View {
    @ObservedObject var installer: OrbitToolInstaller
    var install: () -> Void
    var check: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if installer.running {
                    ProgressView("Installing tools…").controlSize(.small)
                    Button("Cancel", action: installer.cancel)
                } else {
                    Button("Install Mac Tools", action: install)
                    Button("Check Again", action: check)
                }
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
                Text("Leave blank to accept the default.").font(.caption).foregroundStyle(.secondary)
            }
        }.onChange(of: installer.running) { if !installer.running { check() } }
    }
}
