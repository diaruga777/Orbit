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
    @Published var phoneReady = false
    @Published var busy = false
    @Published var message = ""
    @Published var log = ""
    @Published var paired = false
    @Published var loginItem = false
    @Published var loaded = false
    private let setup = OrbitSetup(root: OrbitPaths.root)
    private var work: Task<Void, Never>?
    init() {
        Task {
            do { state = try await setup.load() } catch { message = error.localizedDescription }
            loaded = true
            tools = await setup.checkTools()
            teams = await setup.signingTeams()
            selectDetectedTeam()
        }
    }
    var canContinue: Bool {
        switch state.step {
        case .welcome: return !Bundle.main.bundleURL.path.hasPrefix("/Volumes/")
        case .tools: return tools.ready
        case .access: return state.folderApproved == true
        case .account: return OrbitSetupState.validTeam(state.teamID) && OrbitSetupState.validPrefix(state.bundlePrefix)
        case .phone: return state.installed
        case .agents, .install, .connect, .refresh: return false
        case .complete: return true
        }
    }
    func persist() { let state = state; Task { do { try await setup.save(state) } catch { message = error.localizedDescription } } }
    func next() {
        guard canContinue, !busy else { return }
        if state.step == .complete { state.finished = true; persist(); return }
        let steps = OrbitSetupStep.allCases
        if let index = steps.firstIndex(of: state.step), index + 1 < steps.count { state.step = steps[index + 1]; persist(); message = "" }
    }
    func back() {
        guard !busy, let index = OrbitSetupStep.allCases.firstIndex(of: state.step), index > 0 else { return }
        state.step = OrbitSetupStep.allCases[index - 1]; persist(); message = ""
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = ""
        work = Task {
            defer { busy = false; work = nil }
            do { try await action() } catch is CancellationError { message = "Cancelled. You can pick up here later." } catch { message = error.localizedDescription }
        }
    }
    func checkTools() { perform { self.tools = await self.setup.checkTools(); self.message = self.tools.detail } }
    func selectDetectedTeam() {
        if state.teamID.isEmpty, teams.count == 1 { state.teamID = teams[0].id; persist() }
    }
    func checkAccounts() {
        perform {
            self.teams = await self.setup.signingTeams()
            self.selectDetectedTeam()
            self.message = self.teams.isEmpty ? "Add your Apple Account in Xcode → Settings → Accounts, then check again." : "Your Apple Account is ready."
        }
    }
    func openXcode() {
        let url = URL(fileURLWithPath: tools.developerDirectory).deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }
    func chooseFolder(_ model: OrbitMacModel) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Use Folder"
        panel.directoryURL = URL(fileURLWithPath: state.folder ?? OrbitSetupState.defaultFolder.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.folder = url.path; state.folderApproved = false
        allowFolder(model)
    }
    func allowFolder(_ model: OrbitMacModel) {
        perform {
            let url = URL(fileURLWithPath: self.state.folder ?? OrbitSetupState.defaultFolder.path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Exercise access now so macOS can request Desktop/folder consent.
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            _ = try await model.rpc("setup_folder", ["path": url.path])
            self.state.folder = url.path; self.state.folderApproved = true; self.persist()
            self.message = "Projects folder is ready. Orbit’s local tools run while Orbit is open."
        }
    }
    func changeLoginItem(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginItem = enabled }
        catch { message = error.localizedDescription }
    }
    func listPhones(_ model: OrbitMacModel) {
        perform {
            let rows = try await model.rpc("devices")
            self.devices = try JSONDecoder().decode([CodeDevice].self, from: JSONSerialization.data(withJSONObject: rows))
            if self.state.deviceID.isEmpty, let first = self.devices.first { self.state.deviceID = first.id }
            self.phoneReady = false; self.persist()
            if !self.state.deviceID.isEmpty { self.phoneReady = try await self.setup.phoneReady(self.state.deviceID) }
            if self.devices.isEmpty { self.message = "Unlock your iPhone, connect it by cable, and tap Trust. Open Xcode’s Devices and Simulators if it still doesn’t appear." }
        }
    }
    func install(_ model: OrbitMacModel) {
        perform {
            guard OrbitSetupState.validTeam(self.state.teamID), OrbitSetupState.validPrefix(self.state.bundlePrefix), !self.state.deviceID.isEmpty else { throw CodeFailure("Choose your Apple Account and iPhone first.") }
            self.phoneReady = try await self.setup.phoneReady(self.state.deviceID)
            guard self.phoneReady else { throw CodeFailure("Unlock your iPhone and turn on Developer Mode, then try again.") }
            let source = try await self.setup.prepareSource(); self.state.source = source.path
            _ = try await model.rpc("setup_phone", ["bundlePrefix": self.state.bundlePrefix])
            // Setup installs a source snapshot committed in its own private
            // repository. User namespaces stay build arguments, never source edits.
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
            guard let id = self.state.installJobID else { throw CodeFailure("The build did not start.") }
            while true {
                try Task.checkCancellation()
                let job = try await model.rpc("job", ["id": id]) as? [String: Any] ?? [:]
                self.log = job["log"] as? String ?? ""
                let status = job["state"] as? String ?? "building"
                self.message = ["waitingForPhone": "Waiting for your iPhone. Keep it unlocked and connected.", "installing": "Installing Orbit…", "building": "Building Orbit for your iPhone…"][status] ?? status
                if status == "succeeded" { self.state.installed = true; self.persist(); self.message = "Orbit is installed. Open it on your iPhone to connect."; model.pair(); return }
                if ["failed", "cancelled"].contains(status) {
                    self.state.installJobID = nil; self.persist()
                    throw CodeFailure((job["error"] as? [String: Any])?["recovery"] as? String ?? "Installation stopped. Check the log, fix the issue, then try again.")
                }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }
    func cancelInstall(_ model: OrbitMacModel) {
        work?.cancel()
        if let id = state.installJobID { Task { _ = try? await model.rpc("cancel", ["id": id]) } }
    }
    func exportPairing() {
        perform {
            let directory = OrbitPaths.root.appendingPathComponent("SetupPairing/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("iPhone.mobiledevicepairing")
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/orbit-apple-adapter")
            _ = try await OrbitCommand.run(helper.path, ["--export-pairing", self.state.deviceID, file.path])
            NSWorkspace.shared.activateFileViewerSelecting([file])
            self.message = "AirDrop this file to your iPhone, then import it in Orbit → Refresh → Pairing File. It contains device pairing keys; keep it private and delete the exported copy after importing."
        }
    }
    func checkConnection(_ model: OrbitMacModel) {
        perform {
            let status = try await model.rpc("status") as? [String: Any] ?? [:]
            let config = status["configuration"] as? [String: Any] ?? [:]
            self.paired = !(config["trustedPeers"] as? [String] ?? []).isEmpty
            self.message = self.paired ? "Your iPhone is connected." : "Open Orbit on your iPhone and connect it using this pairing code."
        }
    }
    func installMac() {
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
