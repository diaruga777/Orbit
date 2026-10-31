import UIKit
import OrbitCore

/// Observe navigation and taps without inspecting labels, keyboard input,
/// source text, credentials or any other view contents.
final class OrbitDiagnosticWindow: UIWindow {
    private var screenPath = ""
    override func layoutSubviews() {
        super.layoutSubviews()
        var controller = rootViewController
        var chain: [String] = []
        while let current = controller {
            chain.append(String(describing: type(of: current)))
            if let presented = current.presentedViewController { controller = presented }
            else if let nav = current as? UINavigationController { controller = nav.visibleViewController }
            else if let tabs = current as? UITabBarController { controller = tabs.selectedViewController }
            else { controller = nil }
        }
        let next = chain.joined(separator: "/")
        if next != screenPath { screenPath = next; OrbitDiagnostics.shared.record("screen", "shown", ["controller": next]) }
    }
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches, let touch = event.allTouches?.first, touch.phase == .ended {
            OrbitDiagnostics.shared.record("interaction", "tap", ["view": touch.view.map { String(describing: type(of: $0)) } ?? "unknown", "screen": screenPath])
        }
        super.sendEvent(event)
    }
}
