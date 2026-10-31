import SwiftUI
import AppKit
import OrbitCore
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
            .onAppear { OrbitDiagnostics.shared.record("screen", "mac_window") }
            .onChange(of: model.selectedTab) { _, tab in OrbitDiagnostics.shared.record("screen", "mac_tab", ["tab": tab]) }
            .onChange(of: setup.state.step) { _, step in OrbitDiagnostics.shared.record("screen", "setup_step", ["step": step.rawValue]) }
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
    private var eventMonitor: Any?
    func applicationWillTerminate(_ notification: Notification) { OrbitDiagnostics.shared.record("lifecycle", "terminated") }
    func applicationDidBecomeActive(_ notification: Notification) { OrbitDiagnostics.shared.record("lifecycle", "active") }
    func applicationDidResignActive(_ notification: Notification) { OrbitDiagnostics.shared.record("lifecycle", "inactive") }
    func applicationDidFinishLaunching(_ notification: Notification) { OrbitDiagnostics.shared.record("lifecycle", "launched")
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { event in
            OrbitDiagnostics.shared.record("interaction", "click", ["window": event.window.map { String(describing: type(of: $0)) } ?? "unknown"])
            return event
        }
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
}
