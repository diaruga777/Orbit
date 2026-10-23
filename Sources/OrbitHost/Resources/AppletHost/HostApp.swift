import SwiftUI

@main struct AppletHostApp: App {
    var body: some Scene { WindowGroup { StandaloneAppletRoot() } }
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
            try store.install(script.source)
            UserDefaults.standard.set(OrbitWidgetDefinition.digest(script.source), forKey: "approvedApplet")
            approved = true
        } catch { failure = error.localizedDescription }
    }
}
