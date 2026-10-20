import UIKit
import BackgroundTasks
import OrbitCore
import OrbitUI
import OrbitTransport
import OrbitWire

@main final class OrbitAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let identifier = (Bundle.main.bundleIdentifier ?? "org.example.orbit.ios") + ".overnight-builds"
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task {
                await OrbitPhoneConnection.shared.offerInstallWindow(seconds: 480)
                task.setTaskCompleted(success: !Task.isCancelled)
                Self.requestWindow()
            }
            task.expirationHandler = { work.cancel() }
        }
        Self.requestWindow(); return true
    }
    static func requestWindow() {
        let request = BGProcessingTaskRequest(identifier: (Bundle.main.bundleIdentifier ?? "org.example.orbit.ios") + ".overnight-builds")
        request.requiresNetworkConnectivity = true; request.earliestBeginDate = Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Orbit", sessionRole: session.role)
        configuration.delegateClass = OrbitSceneDelegate.self; return configuration
    }
}
@MainActor final class OrbitSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    let connection = OrbitPhoneConnection.shared
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene); self.window = window
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--editor-preview") {
            window.rootViewController = try? CodeEditorPreview.make(reset: ProcessInfo.processInfo.arguments.contains("--reset-preview"), workspace: ProcessInfo.processInfo.arguments.contains("--workspace-preview"))
            window.makeKeyAndVisible(); return
        }
        #endif
        do {
            let drafts = try CodeDraftStore(root: OrbitPhoneConnection.root.appendingPathComponent("Drafts"))
            let connection = self.connection
            let environment = CodeEnvironment(client: connection.client, drafts: drafts, browse: { path, offset, hidden in
                var params: [String: Any] = ["offset": offset, "hidden": hidden]
                params["path"] = path
                let result = try await connection.rpc("browse", params) as? [String: Any] ?? [:]
                let items = (result["items"] as? [[String: Any]] ?? []).compactMap { item -> CodeBrowserItem? in
                    guard let path = item["path"] as? String, let name = item["name"] as? String, let directory = item["directory"] as? Bool else { return nil }
                    return CodeBrowserItem(path: path, name: name, directory: directory)
                }
                return CodeBrowserPage(items: items, next: (result["next"] as? NSNumber)?.int64Value)
            }, pairing: { OrbitConnectionController(connection: connection) }, peerID: { connection.peerID })
            let tabs = CodeTabsController(environment: environment)
            tabs.loadViewIfNeeded()
            let apps = UINavigationController(rootViewController: OrbitTargetsController(connection: connection))
            apps.tabBarItem = UITabBarItem(title: "Apps", image: UIImage(systemName: "apps.iphone"), tag: 2)
            let settings = UINavigationController(rootViewController: OrbitConnectionController(connection: connection))
            settings.tabBarItem = UITabBarItem(title: "Mac", image: UIImage(systemName: "desktopcomputer"), tag: 3)
            tabs.viewControllers = (tabs.viewControllers ?? []) + [apps, settings]
            if connection.pairingCode.isEmpty { tabs.selectedViewController = settings }
            window.rootViewController = tabs
        } catch {
            let controller = UIViewController(); controller.view.backgroundColor = .systemBackground
            let label = UILabel(); label.text = error.localizedDescription; label.numberOfLines = 0
            label.frame = CGRect(x: 24, y: 180, width: 300, height: 200); controller.view.addSubview(label)
            window.rootViewController = controller
        }
        window.makeKeyAndVisible()
    }
    private var readiness: Task<Void, Never>?
    func sceneDidBecomeActive(_ scene: UIScene) {
        readiness?.cancel()
        readiness = Task { await connection.offerInstallWindow(seconds: 3600) }
    }
    func sceneDidEnterBackground(_ scene: UIScene) { readiness?.cancel(); readiness = nil; OrbitAppDelegate.requestWindow() }
}
final class OrbitPhoneConnection: @unchecked Sendable {
    static let shared = OrbitPhoneConnection()
    private let forwarding = OrbitPhoneForwarding()
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbit", isDirectory: true) }
    let transport = OrbitGoTransport(configuration: .init(stateDirectory: root.appendingPathComponent("Identity"), requestLocalNetworkAccess: true))
    var pairingCode: String {
        get { UserDefaults.standard.string(forKey: "Orbit.pairing") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "Orbit.pairing") }
    }
    var localID: String { UserDefaults.standard.string(forKey: "Orbit.localID") ?? "" }
    var peerID: String { (try? OrbitPairingCode(string: pairingCode).deviceID.description) ?? "unpaired" }
    lazy var client = CodeClient { [self] request in
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any] ?? [:]
        return try JSONSerialization.data(withJSONObject: await rpc("code", object))
    }
    func offerInstallWindow(seconds: Int) async {
        guard !pairingCode.isEmpty else { return }
        do {
            let code = try OrbitPairingCode(string: pairingCode)
            guard let route = code.addresses.first else { return }
            let provider: CodeInstallProvider
            if case .dumbpipe = route { provider = .dumbpipe }
            else if case .relay = route { provider = .syncthing }
            else { provider = .local }
            if case .dumbpipe = route { _ = try await OrbitDumbpipe.shared.start(secretURL: Self.root.appendingPathComponent("Identity/iroh.key")) }
            let local = provider == .dumbpipe ? try await OrbitDumbpipe.shared.start() : try transport.identity()
            let runtime = CodePhoneReverseRuntime(client: client,
                identity: try CodeInstallEndpointIdentity(service: (Bundle.main.bundleIdentifier ?? "org.example.orbit.ios") + ".installation"),
                accountPeerID: local.description, macPeerID: code.deviceID.description,
                generation: peerID, provider: provider, dial: { [transport] in
                    OrbitInstallStream(authenticatedStream: try await transport.dial(route, expecting: code.deviceID))
                }, available: { try Task.checkCancellation() }, open: { service, port in
                    try await OrbitLocalAppleServices.openVerifiedService(service, port: port, interfaces: ["en0", "en1"])
                })
            guard await forwarding.begin(runtime) else { return }
            do {
                if try await runtime.start() { try await Task.sleep(for: .seconds(seconds)) }
            } catch { }
            await runtime.stop(); await forwarding.end(runtime)
        } catch { }
    }
    func prepareIdentity() async throws {
        let code = try OrbitPairingCode(string: pairingCode)
        let id: DeviceID
        if code.addresses.contains(where: { if case .dumbpipe = $0 { return true }; return false }) {
            id = try await OrbitDumbpipe.shared.start(secretURL: Self.root.appendingPathComponent("Identity/iroh.key"))
        } else { id = try transport.identity() }
        UserDefaults.standard.set(id.description, forKey: "Orbit.localID")
    }
    func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        guard !pairingCode.isEmpty else { throw CodeFailure("Connect your Mac first.") }
        let code = try OrbitPairingCode(string: pairingCode)
        guard !code.addresses.isEmpty else { throw CodeFailure("Copy a pairing code with a Mac address.") }
        let payload = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        var last: Error = CodeFailure("Your Mac is unavailable.")
        for route in code.addresses {
            do {
                if case .dumbpipe = route { _ = try await OrbitDumbpipe.shared.start(secretURL: Self.root.appendingPathComponent("Identity/iroh.key")) }
                let stream = try await transport.dial(route, expecting: code.deviceID)
                let response = try JSONSerialization.jsonObject(with: await OrbitRPC.exchange(payload, stream: stream)) as? [String: Any] ?? [:]
                if let message = response["error"] as? String { throw CodeFailure(message) }
                return response["result"] ?? NSNull()
            } catch { last = error }
        }
        throw last
    }
}
@MainActor final class OrbitConnectionController: UITableViewController {
    let connection: OrbitPhoneConnection
    init(connection: OrbitPhoneConnection) { self.connection = connection; super.init(style: .insetGrouped); title = "Orbit Mac" }
    required init?(coder: NSCoder) { fatalError() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 4 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        connection.localID.isEmpty ? nil : "This phone: " + connection.localID
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = ["Connect a Mac", "Check Connection", "Authorize This Phone", "Forget Mac"][indexPath.row]
        if indexPath.row == 0 { cell.detailTextLabel?.text = connection.peerID == "unpaired" ? nil : "Connected Mac saved" }
        cell.accessoryType = .disclosureIndicator; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.row {
        case 0:
            let alert = UIAlertController(title: "Connect Your Mac", message: "In Orbit Mac, choose Connect a Phone and copy its pairing code.", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "orbit://pair?device=…"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no; $0.text = self.connection.pairingCode }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Connect", style: .default) { _ in
                guard let text = alert.textFields?.first?.text else { return }
                Task { do {
                    _ = try OrbitPairingCode(string: text); self.connection.pairingCode = text
                    try await self.connection.prepareIdentity(); self.tableView.reloadData()
                    _ = try await self.connection.rpc("status"); self.tableView.reloadData(); self.message("Connected")
                } catch { self.message(error.localizedDescription) } }
            }); present(alert, animated: true)
        case 1: Task { do { _ = try await connection.rpc("status"); message("Your Mac is ready.") } catch { message(error.localizedDescription) } }
        case 2: CodePhoneAuthorization.choose(client: connection.client, from: self) { [weak self] text in self?.message(text) }
        default: connection.pairingCode = ""; tableView.reloadData()
        }
    }
    func message(_ text: String) { let alert = UIAlertController(title: "Orbit", message: text, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true) }
}

private actor OrbitPhoneForwarding {
    private var active: CodePhoneReverseRuntime?
    func begin(_ value: CodePhoneReverseRuntime) -> Bool { guard active == nil else { return false }; active = value; return true }
    func end(_ value: CodePhoneReverseRuntime) { if active === value { active = nil } }
}
