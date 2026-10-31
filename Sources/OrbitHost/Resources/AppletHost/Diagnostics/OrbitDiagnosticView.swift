#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Install on each meaningful screen using a fixed developer-authored ID.
    /// Actions should additionally call OrbitAppDiagnostics.action before mutation.
    func orbitDiagnostics(_ screen: String) -> some View {
        modifier(OrbitDiagnosticView(screen: screen))
    }
}
private struct OrbitDiagnosticView: ViewModifier {
    let screen: String
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.simultaneousGesture(TapGesture().onEnded { OrbitAppDiagnostics.record("interaction.tap", screen) })
            .onAppear { OrbitAppDiagnostics.screen(screen) }
            .onDisappear { OrbitAppDiagnostics.record("screen.left", screen) }
            .onChange(of: phase) { _, value in
                OrbitAppDiagnostics.record("lifecycle", value == .active ? "active" : (value == .background ? "background" : "inactive"))
            }
    }
}
#endif
