import SwiftUI
import UIKit
import UserNotifications

@main struct AppletHostApp: App {
    @UIApplicationDelegateAdaptor(AppletHostDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup { StandaloneAppletRoot() }
        .onChange(of: phase) { _, phase in
            if phase == .active { OrbitAppletBackground.shared.foreground() }
            else { OrbitAppletBackground.shared.background() }
        }
    }
}

private final class AppletHostDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        OrbitAppletBackground.shared.allowedSource = { source in
            guard let url = Bundle.main.url(forResource: "Applet", withExtension: "js"),
                  let bundled = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return source == bundled && UserDefaults.standard.string(forKey: "approvedApplet") == OrbitWidgetDefinition.digest(bundled)
        }
        OrbitAppletBackground.shared.register()
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

private struct StandaloneAppletRoot: View {
    @State private var script: OrbitWidgetScript?
    @State private var approved = false
    @State private var failure: String?
    private let store = OrbitWidgetStore(applets: true)
    var body: some View {
        NavigationStack {
            if let script, approved { OrbitAppletView(script: script, store: store) }
            else if let script {
                VStack(spacing: 20) {
                    Text(script.definition.name).font(.largeTitle.bold())
                    Text(script.definition.domains.isEmpty ? "No network access." : "Websites: " + script.definition.domains.joined(separator: ", "))
                    if let consent = try? OrbitAppletDefinition.parse(script.source).pollingConsent { Text(consent) }
                    Text("This applet can save its own data on your phone. Only open code you trust.")
                    Button("Open Applet") { approve(script) }.buttonStyle(.borderedProminent)
                    if let failure { Text(failure).foregroundStyle(.red) }
                }.padding()
            } else { Text(failure ?? "Loading…").padding() }
        }.task {
            do {
                guard let url = Bundle.main.url(forResource: "Applet", withExtension: "js") else { throw OrbitWidgetError("The applet file is missing.") }
                let source = try String(contentsOf: url, encoding: .utf8)
                let checked = try OrbitAppletDefinition.widgetScript(source)
                script = checked
                if UserDefaults.standard.string(forKey: "approvedApplet") == OrbitWidgetDefinition.digest(source) { approve(checked) }
            } catch { failure = error.localizedDescription }
        }
    }
    private func approve(_ script: OrbitWidgetScript) {
        do {
            if try store.script(script.id)?.source != script.source { try store.install(script.source) }
            UserDefaults.standard.set(OrbitWidgetDefinition.digest(script.source), forKey: "approvedApplet")
            approved = true
            OrbitAppletBackground.shared.foreground()
        } catch { failure = error.localizedDescription }
    }
}
