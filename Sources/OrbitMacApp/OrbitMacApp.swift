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
                if !setup.loaded { ProgressView().frame(minWidth: 760, minHeight: 540) }
                else if setup.state.finished { OrbitMacView(model: model, setup: setup).frame(minWidth: 760, minHeight: 540) }
                else { OrbitSetupView(setup: setup, model: model) }
            }
            .onAppear { OrbitDiagnostics.shared.record("screen", "mac_window") }
            .onChange(of: model.selectedTab) { _, tab in OrbitDiagnostics.shared.record("screen", "mac_tab", ["tab": tab]) }
            .onChange(of: setup.state.step) { _, step in OrbitDiagnostics.shared.record("screen", "setup_step", ["step": step.rawValue]) }
            .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: model.acceptDrop)
            .alert("Couldn’t Import", isPresented: $model.scriptImportFailed) { Button("OK", role: .cancel) {} } message: { Text(model.scriptMessage) }
        }.commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Orbit Mac") { showAbout() }
            }
            CommandGroup(after: .appSettings) {
                Button("Show Client Logs") { NSWorkspace.shared.open(OrbitDiagnostics.defaultDirectory) }
                Button("Setup…") { setup.state.finished = false; setup.state.step = .welcome; setup.persist() }
            }
        }
        Settings {
            OrbitConnectionsView(model: model)
                .padding(20)
                .frame(width: 520)
        }
        MenuBarExtra {
            Button("Open Orbit") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            Button("Quit Orbit") { NSApp.terminate(nil) }
        } label: {
            Image(nsImage: OrbitMenuBarIcon.image)
                .accessibilityLabel("Orbit")
        }
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Orbit Mac"
        alert.informativeText = "Bundle ID"
        let identifier = NSTextField(labelWithString: Bundle.main.bundleIdentifier ?? "Unavailable")
        identifier.isSelectable = true
        identifier.lineBreakMode = .byTruncatingMiddle
        identifier.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        alert.accessoryView = identifier
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

// Flat device silhouettes from the app icon, redrawn for the menu bar.
private enum OrbitMenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let orbit = NSBezierPath()
            orbit.move(to: NSPoint(x: 16, y: 15))
            orbit.curve(to: NSPoint(x: 2, y: 3),
                        controlPoint1: NSPoint(x: 7, y: 16), controlPoint2: NSPoint(x: -2, y: 7))
            orbit.curve(to: NSPoint(x: 20, y: 10),
                        controlPoint1: NSPoint(x: 6, y: -2), controlPoint2: NSPoint(x: 22, y: 3))
            orbit.lineWidth = 0.9
            orbit.lineCapStyle = .round
            orbit.stroke()

            NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 10, height: 8),
                         xRadius: 0.8, yRadius: 0.8).fill()
            let base = NSBezierPath()
            base.move(to: NSPoint(x: 5, y: 4))
            base.line(to: NSPoint(x: 15, y: 4))
            base.line(to: NSPoint(x: 17, y: 2.5))
            base.line(to: NSPoint(x: 3, y: 2.5))
            base.close()
            base.fill()

            let phone = NSBezierPath(roundedRect: NSRect(x: 17, y: 11, width: 3.5, height: 6.5),
                                     xRadius: 0.7, yRadius: 0.7)
            var tilt = AffineTransform()
            tilt.translate(x: 18.75, y: 14.25)
            tilt.rotate(byDegrees: -14)
            tilt.translate(x: -18.75, y: -14.25)
            phone.transform(using: tilt)
            phone.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Orbit"
        return image
    }()
}
