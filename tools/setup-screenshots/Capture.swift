import AppKit
import SwiftUI

// Screenshot-only models. Every action is inert, including bindings that would
// normally persist settings. Values below are fictional, never user state.
@MainActor enum ScreenshotEnvironment { static var fromDiskImage = false }
@MainActor final class OrbitMacModel: ObservableObject {
    @Published var pairing = ""
    func pair() {}
}
@MainActor final class OrbitSetupModel: ObservableObject {
    @Published var state = OrbitSetupState()
    @Published var tools = OrbitToolReadiness()
    let installer = OrbitToolInstaller()
    @Published var teams: [OrbitSigningTeam] = []
    @Published var devices: [CodeDevice] = []
    @Published var phoneReady: Bool?
    @Published var installing = false
    @Published var discoveryError = ""
    @Published var busy = false
    @Published var message = ""
    @Published var log = ""
    @Published var loginItem = false
    // MODEL_PROPERTIES
    func back() {}
    func finish() {}
    func persist() {}
    func installMac() {}
    func checkTools() {}
    func installTools() {}
    func checkAccounts() {}
    func openXcode() {}
    func allowFolder(_ model: OrbitMacModel) {}
    func chooseFolder(_ model: OrbitMacModel) {}
    func changeLoginItem(_ enabled: Bool) {}
    func listPhones() async {}
    func checkSelectedDevice() async {}
    func install(_ model: OrbitMacModel) {}
    func cancelInstall(_ model: OrbitMacModel) {}
    func checkConnection(_ model: OrbitMacModel) {}
    func exportPairing() {}
}

struct OrbitSigningTeam: Identifiable { var id: String; var name: String }
@MainActor final class OrbitToolInstaller: ObservableObject {
    @Published var running = false
    @Published var output = ""
    @Published var response = ""
    func start() {}
    func send() {}
    func cancel() {}
}

@main struct Capture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Orbit Mac"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        var captures: [[String: String]] = []
        let variants: [(String, OrbitSetupStep, String)] = [
            ("00-install-on-mac", .mac, "disk-image"),
            ("01-missing-tools", .mac, "missing"),
            ("02-private-installer", .mac, "sign-in"),
            ("03-account", .mac, "account"),
            ("04-choose-team", .mac, "teams"),
            ("05-projects-folder", .mac, "folder"),
            ("06-connect-device", .phone, "missing-device"),
            ("07-choose-device", .phone, "multiple"),
            ("08-iphone", .phone, "ready"),
            ("09-ipad-developer-mode", .phone, "developer"),
            ("10-system-update", .phone, "update"),
            ("11-installing", .phone, "building"),
            ("12-scan", .phone, "verified")
        ]
        for (name, step, variant) in variants {
            ScreenshotEnvironment.fromDiskImage = variant == "disk-image"
            let setup = OrbitSetupModel()
            let model = OrbitMacModel()
            setup.state.step = step
            setup.state.folder = "/Users/demo/Desktop/Orbit"
            setup.state.teamID = ["teams", "account"].contains(variant) ? "" : "DEMO123456"
            setup.teams = variant == "account" ? [] : [.init(id: "DEMO123456", name: "Personal Team")]
            if variant == "teams" { setup.teams.append(.init(id: "DEMO789012", name: "Studio")) }
            setup.tools.xcode = true
            setup.tools.firstLaunch = true
            setup.tools.iOSSDK = true
            setup.tools.python = true
            setup.tools.developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
            if ["missing", "sign-in"].contains(variant) { setup.tools = OrbitToolReadiness() }
            if variant == "sign-in" {
                setup.installer.running = true
                setup.installer.output = "Enter the verification code sent to your device:"
            }
            let phone = CodeDevice(id: "phone", name: "Demo iPhone", modelCode: "iPhone17,1", modelName: "iPhone 16 Pro",
                                   operatingSystemVersion: variant == "update" ? "18.6 (fixture)" : "26.2 (fixture)")
            let pad = CodeDevice(id: "pad", name: "Demo iPad", modelCode: "iPad14,1", modelName: "iPad mini", operatingSystemVersion: "26.2")
            setup.devices = variant == "multiple" ? [phone, pad] : variant == "developer" ? [pad] : variant == "missing-device" ? [] : [phone]
            setup.state.deviceID = setup.devices.count == 1 ? setup.devices[0].id : ""
            setup.phoneReady = variant != "developer"
            setup.installing = variant == "building"
            setup.busy = setup.installing
            if setup.installing { setup.message = "Building Orbit…" }
            setup.state.installed = variant == "verified"
            if setup.state.installed { model.pairing = "orbit://pair?device=" + String(repeating: "A", count: 52) + "&address=tcp%3A%2F%2F192.0.2.1%3A22000" }
            let compact = ["developer", "verified"].contains(variant)
            let size = compact ? NSSize(width: 760, height: 540) : NSSize(width: 1000, height: 740)
            window.appearance = NSAppearance(named: variant == "developer" ? .darkAqua : .aqua)
            let view = NSHostingView(rootView: OrbitSetupView(setup: setup, model: model)
                .environment(\.colorScheme, variant == "developer" ? .dark : .light)
                .environment(\.controlActiveState, .active)
                .allowsHitTesting(false)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = view
            window.setContentSize(size)
            window.orderFront(nil)
            // Allow SwiftUI layout/materials to settle before bitmap capture.
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fatalError("Could not allocate screenshot: \(name)")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("Could not encode screenshot: \(name)")
            }
            do { try png.write(to: output.appendingPathComponent(name + ".png")) }
            catch { fatalError("Could not save screenshot: \(error)") }
            captures.append(["file": name + ".png", "step": step.rawValue, "variant": variant, "width": String(Int(size.width)), "height": String(Int(size.height))])
        }
        let manifest: [String: Any] = ["mock": true, "view": "Sources/OrbitMacApp/OrbitSetupView.swift",
                                      "captures": captures]
        do {
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("manifest.json"))
        } catch { fatalError("Could not save manifest: \(error)") }
        window.close()
    }
}
