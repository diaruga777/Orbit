import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main struct OrbitMacApplication: App {
    @NSApplicationDelegateAdaptor(OrbitMacDelegate.self) private var delegate
    @StateObject private var model = OrbitMacModel()
    @StateObject private var setup = OrbitSetupModel()
    var body: some Scene {
        WindowGroup("Orbit Mac") {
            Group {
                if !setup.loaded { ProgressView().frame(width: 850, height: 660) }
                else if setup.state.finished { OrbitMacView(model: model, setup: setup).frame(minWidth: 760, minHeight: 540) }
                else { OrbitSetupView(setup: setup, model: model) }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: model.acceptDrop)
            .alert("Couldn’t Import", isPresented: $model.scriptImportFailed) { Button("OK", role: .cancel) {} } message: { Text(model.scriptMessage) }
        }.commands {
            CommandGroup(after: .appSettings) {
                Button("Setup…") { setup.state.finished = false; setup.state.step = .welcome; setup.persist() }
            }
        }
        MenuBarExtra("Orbit", systemImage: "sparkles") {
            Button("Open Orbit") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            Button("Quit Orbit") { NSApp.terminate(nil) }
        }
    }
}
final class OrbitMacDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
}
