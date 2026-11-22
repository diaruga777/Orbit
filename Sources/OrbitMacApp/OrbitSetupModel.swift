import SwiftUI
import AppKit
import ServiceManagement
import OrbitHost
import OrbitCore

@MainActor final class OrbitSetupModel: ObservableObject {
    @Published var state = OrbitSetupState()
    @Published var tools = OrbitToolReadiness()
    let installer = OrbitToolInstaller()
    @Published var teams: [OrbitSigningTeam] = []
    @Published var devices: [CodeDevice] = []
    @Published var phoneReady: Bool?
    @Published var installing = false
    @Published var busy = false
    @Published var message = ""
    @Published var log = ""
    @Published var loginItem = false
    @Published var loaded = false
    private let setup = OrbitSetup(root: OrbitPaths.root)
    private var work: Task<Void, Never>?
    init() {
        Task {
            do { state = try await setup.load() } catch { OrbitDiagnostics.shared.error("setup", "failed", error); message = error.localizedDescription }
            tools = await setup.checkTools()
            teams = await setup.signingTeams()
            selectDetectedTeam()
            loginItem = SMAppService.mainApp.status == .enabled
            loaded = true
        }
    }
    var fromDiskImage: Bool { Bundle.main.bundleURL.path.hasPrefix("/Volumes/") }
    var signingReady: Bool { OrbitSetupState.validTeam(state.teamID) && OrbitSetupState.validPrefix(state.bundlePrefix) }
    var selectedDevice: CodeDevice? { devices.first { $0.id == state.deviceID } }
    func persist() { let state = state; Task { do { try await setup.save(state) } catch { OrbitDiagnostics.shared.error("setup", "failed", error); message = error.localizedDescription } } }
    func finish() {
        guard state.installed, !busy else { return }
        state.finished = true
        persist()
    }
    func back() {
        guard !busy else { return }
        state.step = .mac
        message = ""
        persist()
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = ""
        work = Task {
            defer { busy = false; work = nil }
            do { try await action() } catch is CancellationError { message = "Cancelled. You can pick up here later." } catch { OrbitDiagnostics.shared.error("setup", "failed", error); message = error.localizedDescription }
        }
    }
    func checkTools() { perform { self.tools = await self.setup.checkTools(); self.teams = await self.setup.signingTeams(); self.selectDetectedTeam(); self.message = self.tools.ready ? "" : self.tools.detail } }
    func installTools() {
        OrbitDiagnostics.shared.record("action", "setup_installTools")
        perform {
            self.tools = await self.setup.checkTools()
            let version: String?
            if !self.tools.xcode || !self.tools.iOSSDK {
                self.message = "Finding Xcode for your Mac…"
                version = try await self.setup.recommendedXcode()
            } else { version = nil }
            self.installer.start(xcodeVersion: version)
        }
    }
    func selectDetectedTeam() {
        if state.teamID.isEmpty, teams.count == 1 { state.teamID = teams[0].id; persist() }
    }
    func checkAccounts() {
        perform {
            self.teams = await self.setup.signingTeams()
            self.selectDetectedTeam()
        }
    }
    func openXcode() {
        OrbitDiagnostics.shared.record("action", "setup_openXcode")
        let url = URL(fileURLWithPath: tools.developerDirectory).deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }
    func chooseFolder(_ model: OrbitMacModel) {
        OrbitDiagnostics.shared.record("action", "setup_chooseFolder")
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Use Folder"
        panel.directoryURL = URL(fileURLWithPath: state.folder ?? OrbitSetupState.defaultFolder.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.folder = url.path; state.folderApproved = false; persist()
        if tools.ready && signingReady { allowFolder(model) }
    }
    func allowFolder(_ model: OrbitMacModel) {
        OrbitDiagnostics.shared.record("action", "setup_allowFolder")
        guard tools.ready, signingReady, !fromDiskImage else { return }
        perform {
            let url = URL(fileURLWithPath: self.state.folder ?? OrbitSetupState.defaultFolder.path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Exercise access now so macOS can request Desktop/folder consent.
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            _ = try await model.rpc("setup_folder", ["path": url.path])
            self.state.folder = url.path; self.state.folderApproved = true
            self.state.step = .phone
            self.persist()
        }
    }
    func changeLoginItem(_ enabled: Bool) {
        OrbitDiagnostics.shared.record("action", "setup_changeLoginItem")
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginItem = enabled }
        catch { message = error.localizedDescription }
    }
    func listPhones(_ model: OrbitMacModel) async {
        guard !busy, !Task.isCancelled else { return }
        do {
            let rows = try await model.rpc("devices")
            try Task.checkCancellation()
            guard state.step.current == .phone, !installing else { return }
            self.devices = try JSONDecoder().decode([CodeDevice].self, from: JSONSerialization.data(withJSONObject: rows))
            if self.state.deviceID.isEmpty, self.devices.count == 1 {
                self.state.deviceID = self.devices[0].id
                self.persist()
            }
            await checkSelectedDevice()
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }
    func checkSelectedDevice() async {
        guard let device = selectedDevice, !device.needsSystemUpdate, !state.installed, state.installJobID == nil else { return }
        let ready = try? await setup.phoneReady(device.id)
        if !Task.isCancelled, state.deviceID == device.id { phoneReady = ready }
    }
    func install(_ model: OrbitMacModel) {
        OrbitDiagnostics.shared.record("action", "setup_install")
        perform {
            self.installing = true
            defer { self.installing = false }
            if self.state.installJobID == nil {
                guard self.signingReady, let device = self.selectedDevice, !device.needsSystemUpdate else { throw CodeFailure("Choose a signing team and device.") }
                guard try await self.setup.phoneReady(device.id) else {
                    self.phoneReady = false
                    throw CodeFailure("Unlock your device and check Developer Mode.")
                }
                try await self.startInstall(model)
            }
            try await self.followInstall(model)
        }
    }
    private func startInstall(_ model: OrbitMacModel) async throws {
        let source = try await self.setup.prepareSource(); self.state.source = source.path
        try await self.setup.configureSource(source, state: self.state)
        _ = try await model.rpc("setup_phone", ["bundlePrefix": self.state.bundlePrefix,
            "bundleID": self.state.iosBundleID ?? self.state.bundlePrefix + ".ios"])
        // Setup installs a source snapshot committed in its own private
        // repository. Its identity lives in ignored local configuration.
        if let old = self.state.installTargetID, self.state.installJobID == nil {
            let rows = try await model.rpc("targets") as? [[String: Any]] ?? []
            let target = rows.first { $0["id"] as? String == old }
            let project = target?["project"] as? [String: Any] ?? [:]
            if target?["deviceID"] as? String != self.state.deviceID || project["developmentTeam"] as? String != self.state.teamID {
                if target != nil { _ = try await model.rpc("target_remove", ["id": old]) }
                self.state.installTargetID = nil; self.persist()
            }
        }
        if self.state.installTargetID == nil {
            let target = try await model.rpc("target_add", ["project": source.appendingPathComponent("Orbit.xcodeproj").path,
                "scheme": "Orbit", "deviceID": self.state.deviceID, "teamID": self.state.teamID,
                "bundlePrefix": self.state.bundlePrefix, "account": "free", "enabled": false, "trust": true, "branch": "main"]) as? [String: Any] ?? [:]
            self.state.installTargetID = target["id"] as? String; self.persist()
        }
        guard let target = self.state.installTargetID else { throw CodeFailure("Orbit did not register its installer.") }
        if self.state.installJobID == nil {
            let job = try await model.rpc("build", ["id": target]) as? [String: Any] ?? [:]
            self.state.installJobID = job["id"] as? String; self.persist()
        }
    }
    private func followInstall(_ model: OrbitMacModel) async throws {
        guard let id = self.state.installJobID else { throw CodeFailure("The build did not start.") }
        while true {
            try Task.checkCancellation()
            let job = try await model.rpc("job", ["id": id]) as? [String: Any] ?? [:]
            self.log = job["log"] as? String ?? ""
            let status = job["state"] as? String ?? "building"
            self.message = ["waitingForPhone": "Waiting for your device…", "installing": "Installing Orbit…", "building": "Building Orbit…"][status] ?? status
            if status == "succeeded" { self.state.installed = true; self.persist(); self.message = ""; model.pair(); return }
            if ["failed", "cancelled"].contains(status) {
                self.state.installJobID = nil; self.persist()
                throw CodeFailure((job["error"] as? [String: Any])?["recovery"] as? String ?? "Installation stopped. Check the log, fix the issue, then try again.")
            }
            try await Task.sleep(for: .seconds(2))
        }
    }
    func cancelInstall(_ model: OrbitMacModel) {
        OrbitDiagnostics.shared.record("action", "setup_cancelInstall")
        work?.cancel()
        if let id = state.installJobID { Task { _ = try? await model.rpc("cancel", ["id": id]) } }
    }
    func exportPairing() {
        OrbitDiagnostics.shared.record("action", "setup_exportPairing")
        perform {
            self.message = "Exporting your iPhone’s pairing file…"
            let file = try await OrbitPairingExport.export(deviceID: self.state.deviceID, root: OrbitPaths.root)
            NSWorkspace.shared.activateFileViewerSelecting([file])
            self.message = "Pairing file ready. AirDrop it to your iPhone, then open Orbit → More → Phone-only refresh → Pairing File to import it. Keep it private and delete the exported copy afterward."
        }
    }
    func installMac() {
        OrbitDiagnostics.shared.record("action", "setup_installMac")
        perform {
            let source = Bundle.main.bundleURL
            guard source.pathExtension == "app" else { throw CodeFailure("Open Orbit from its DMG to install it.") }
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("Orbit Mac.app")
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                // Updating an installed persistent client needs the same signed
                // identity. Let Finder handle an explicit replacement decision.
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                throw CodeFailure("Orbit is already installed. Open that copy, or replace it in Finder after quitting Orbit.")
            }
            _ = try await OrbitCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
            try FileManager.default.copyItem(at: source, to: destination)
            let configuration = NSWorkspace.OpenConfiguration(); configuration.createsNewApplicationInstance = true
            try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
            NSApp.terminate(nil)
        }
    }
}
