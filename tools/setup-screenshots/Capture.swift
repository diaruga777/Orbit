import AppKit
import SwiftUI

// Screenshot-only models. Every action is inert, including bindings that would
// normally persist settings. Values below are fictional, never user state.
struct ScreenshotPhone { var id: String; var name: String }
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
    @Published var devices = [ScreenshotPhone(id: "screenshot-phone", name: "Demo iPhone")]
    @Published var phoneReady = false
    @Published var busy = false
    @Published var message = ""
    @Published var log = ""
    @Published var paired = false
    @Published var phoneRefreshReady = false
    @Published var loginItem = false
    // CONTINUE_GATE
    func back() {}
    func next() {}
    func persist() {}
    func installMac() {}
    func checkTools() {}
    func checkAccounts() {}
    func openXcode() {}
    func allowFolder(_ model: OrbitMacModel) {}
    func chooseFolder(_ model: OrbitMacModel) {}
    func changeLoginItem(_ enabled: Bool) {}
    func listPhones(_ model: OrbitMacModel) {}
    func checkPhone() {}
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
            ("00-install-on-mac", .welcome, "disk-image"),
            ("01-welcome", .welcome, "default"),
            ("02-mac-tools", .tools, "ready"),
            ("03-mac-access", .access, "default"),
            ("04-apple-account", .account, "default"),
            ("05-your-iphone", .phone, "default"),
            ("06-ready", .complete, "default"),
            ("07-tools-missing", .tools, "missing"),
            ("08-tools-first-launch", .tools, "first-launch"),
            ("09-tools-sign-in", .tools, "sign-in"),
            ("10-account-detected", .account, "detected"),
            ("11-install-in-progress", .phone, "building"),
            ("12-install-verified", .phone, "verified")
        ]
        for (name, step, variant) in variants {
            ScreenshotEnvironment.fromDiskImage = variant == "disk-image"
            let setup = OrbitSetupModel()
            let model = OrbitMacModel()
            setup.state.step = step
            setup.state.folder = "/Users/demo/Desktop/Orbit"
            setup.state.folderApproved = true
            setup.state.teamID = "DEMO123456"
            setup.state.bundlePrefix = "org.example.orbit.demo"
            setup.state.deviceID = "screenshot-phone"
            setup.tools.xcode = true
            setup.tools.firstLaunch = true
            setup.tools.iOSSDK = true
            setup.tools.python = true
            setup.tools.developerDirectory = "/Applications/Xcode.app/Contents/Developer"
            setup.phoneReady = true
            setup.paired = true
            setup.phoneRefreshReady = true
            setup.loginItem = true
            if step == .tools {
                if variant == "missing" {
                    setup.tools = OrbitToolReadiness()
                    setup.message = "Install the full Xcode app to build iPhone apps."
                } else if variant == "first-launch" {
                    setup.tools.firstLaunch = false
                    setup.tools.iOSSDK = false
                    setup.message = "Finish Xcode’s setup, then check again."
                } else if variant == "sign-in" {
                    setup.tools = OrbitToolReadiness()
                    setup.installer.running = true
                    setup.installer.output = "Installing Xcode with xcodes…\nApple ID: demo@example.invalid\nEnter the verification code sent to your device:"
                } else { setup.message = "Xcode and iOS 26.2 tools are ready." }
            }
            if step == .phone { setup.message = "Developer Mode is on. Your iPhone is ready." }
            if step == .account && variant == "detected" { setup.teams = [.init(id: "DEMO123456", name: "Demo (Personal Team)")] }
            if step == .phone && ["building", "verified"].contains(variant) {
                setup.state.installJobID = "screenshot-job"
                setup.log = "[Mock preview] Preparing committed source…\nBuilding Orbit for iPhone…\nSigning with the selected Personal Team…"
                if variant == "building" {
                    setup.busy = true
                    setup.message = "Building Orbit for your iPhone…"
                } else {
                    setup.state.installed = true
                    model.pairing = "ORBIT-DEMO-PAIRING-CODE (mock preview)"
                    setup.message = "Orbit is installed. Open it on your iPhone to connect."
                }
            }
            let view = NSHostingView(rootView: OrbitSetupView(setup: setup, model: model)
                .environment(\.colorScheme, .light)
                .environment(\.controlActiveState, .active)
                .allowsHitTesting(false)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = view
            window.setContentSize(NSSize(width: 1000, height: 740))
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
            captures.append(["file": name + ".png", "step": step.rawValue, "variant": variant])
        }
        let manifest: [String: Any] = ["mock": true, "view": "Sources/OrbitMacApp/OrbitSetupView.swift",
                                      "contentSize": [1000, 740], "captures": captures]
        do {
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("manifest.json"))
        } catch { fatalError("Could not save manifest: \(error)") }
        window.close()
    }
}
