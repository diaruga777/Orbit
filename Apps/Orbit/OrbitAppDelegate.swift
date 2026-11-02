import UIKit
import BackgroundTasks
import OrbitCore
import OrbitRefresh
import OrbitWidgetUI
import OrbitAppletUI
import OrbitWidgets
import OrbitUI
import OrbitTransport
import OrbitWire

@main final class OrbitAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        OrbitDiagnostics.shared.record("lifecycle", "launched", ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", "revision": Bundle.main.object(forInfoDictionaryKey: "OrbitSourceRevision") as? String ?? "unknown"])
        OrbitExpiryNotifications.shared.start()
        OrbitAppletBackground.shared.register()
        CodeRefreshBackground.register()
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
/// Keep destination identity separate from UIKit's legacy viewControllers API,
/// which is unavailable after adopting UITab for the system sidebar.
@MainActor class OrbitTabBarController: UITabBarController {
    let destinations: [UIViewController]
    init(destinations: [UIViewController]) {
        self.destinations = destinations
        super.init(nibName: nil, bundle: nil)
        mode = .tabSidebar
        tabs = destinations.map { controller in
            UITab(title: controller.tabBarItem.title ?? "", image: controller.tabBarItem.image,
                  identifier: String(controller.tabBarItem.tag)) { _ in controller }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    var destinationIndex: Int {
        get { tabs.firstIndex { $0 === selectedTab } ?? 0 }
        set { if tabs.indices.contains(newValue) { selectedTab = tabs[newValue] } }
    }
}

@MainActor final class OrbitSceneDelegate: UIResponder, UIWindowSceneDelegate, UITabBarControllerDelegate {
    var window: UIWindow?
    private var inertPreview = false
    private var widgets: OrbitWidgetsController?
    private var applets: OrbitWidgetsController?
    let connection = OrbitPhoneConnection.shared
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = OrbitDiagnosticWindow(windowScene: scene); self.window = window
        #if DEBUG && targetEnvironment(simulator)
        inertPreview = ["--target-build-preview", "--target-icons-preview", "--refresh-sign-in-fixture", "--editor-preview", "--optional-setup-fixture"].contains(where: ProcessInfo.processInfo.arguments.contains)
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--refresh-sign-in-fixture"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            window.rootViewController = CodeRefreshSignInPreview.make(scenario: ProcessInfo.processInfo.arguments[index + 1])
            window.makeKeyAndVisible(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--target-build-preview") {
            window.rootViewController = try? OrbitTargetBuildPreview.make()
            window.makeKeyAndVisible(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--target-icons-preview") {
            let icon = UIGraphicsImageRenderer(size: CGSize(width: 132, height: 132)).image { context in
                UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 132, height: 132))
                UIImage(systemName: "moon.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 32, y: 32, width: 68, height: 68))
            }.pngData()!.base64EncodedString()
            let controller = OrbitTargetsController(rpc: { _, _ in
                [["id": "preview", "name": "Luna", "iconPNG": icon, "lastSuccess": Date().addingTimeInterval(-14 * 3600).timeIntervalSinceReferenceDate],
                 ["id": "missing", "name": "No Icon", "lastSuccess": Date().addingTimeInterval(-2 * 86400).timeIntervalSinceReferenceDate],
                 ["id": "invalid", "name": "Invalid Icon", "iconPNG": "invalid"]]
            })
            window.rootViewController = UINavigationController(rootViewController: controller)
            window.makeKeyAndVisible(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--open-expiry-notification") {
            UserDefaults.standard.set(true, forKey: "Orbit.dismissedExtraSetup")
            UserDefaults.standard.set(true, forKey: "Orbit.openRefreshSetup")
        }
        if ProcessInfo.processInfo.arguments.contains("--reset-connection") { connection.pairingCode = "" }
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
            }, pairing: { OrbitConnectionController(connection: connection) }, peerID: { connection.peerID }, jobStatus: { id in
                try CodeJob.targetStatus(JSONSerialization.data(withJSONObject: await connection.rpc("job", ["id": id])))
            }, preparePhoneInstall: { try await OrbitInstallNetwork.requireWiFi() })
            environment.builds.activated()
            let project = CodeWorkspaceController(environment: environment)
            project.tabBarItem = UITabBarItem(title: "Project", image: UIImage(systemName: "curlybraces"), tag: 0)
            let apps = UINavigationController(rootViewController: OrbitTargetsController(connection: connection, monitor: environment.builds))
            apps.tabBarItem = UITabBarItem(title: "Apps", image: UIImage(systemName: "apps.iphone"), tag: 2)
            let refreshController = CodeRefreshController()
            refreshController.readinessChanged = { readiness in Task { _ = try? await connection.rpc("phone_setup_status", readiness) } }
            let widgets = OrbitWidgetsController(deployments: {
                let result = try await connection.rpc("widgets") as? [[String: Any]] ?? []
                return result.compactMap { $0["source"] as? String }
            })
            self.widgets = widgets
            let widgetNavigation = UINavigationController(rootViewController: widgets)
            widgetNavigation.tabBarItem = UITabBarItem(title: "Widgets", image: UIImage(systemName: "square.grid.2x2"), tag: 5)
            let applets = OrbitWidgetsController(deployments: {
                let result = try await connection.rpc("applets") as? [[String: Any]] ?? []
                return result.compactMap { $0["source"] as? String }
            }, applets: true)
            self.applets = applets
            let appletNavigation = UINavigationController(rootViewController: applets)
            appletNavigation.tabBarItem = UITabBarItem(title: "Applets", image: UIImage(systemName: "curlybraces.square"), tag: 6)
            widgets.routeImport = { [weak self] file in self?.reviewFile(file) }
            applets.routeImport = { [weak self] file in self?.reviewFile(file) }
            let menu = OrbitSettingsController(connection: connection, refreshController: refreshController)
            #if DEBUG && targetEnvironment(simulator)
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--optional-setup-fixture"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                let fixture = ProcessInfo.processInfo.arguments[index + 1]
                menu.setupStatus = { (fixture == "refresh" || fixture == "both", fixture == "remote" || fixture == "both") }
            }
            #endif
            let more = UINavigationController(rootViewController: menu)
            more.tabBarItem = UITabBarItem(title: "More", image: UIImage(systemName: "ellipsis.circle"), tag: 7)
            let tabs = OrbitMainTabController(destinations: [project, apps, appletNavigation, widgetNavigation, more])
            menu.badgeChanged = { [weak tabs] needed in tabs?.tabs.last?.badgeValue = needed ? "!" : nil }
            menu.updateStatus()
            tabs.delegate = self
            widgets.pendingCountChanged = { [weak tabs] count in tabs?.tabs[3].badgeValue = count == 0 ? nil : String(count) }
            applets.pendingCountChanged = { [weak tabs] count in tabs?.tabs[2].badgeValue = count == 0 ? nil : String(count) }
            widgets.refreshInbox(); applets.refreshInbox()
            tabs.destinationIndex = connection.pairingCode.isEmpty ? 4 : min(4, max(0, UserDefaults.standard.integer(forKey: "Orbit.selectedTab")))
            window.rootViewController = tabs
        } catch {
            let controller = UIViewController(); controller.view.backgroundColor = .systemBackground
            let label = UILabel(); label.text = error.localizedDescription; label.numberOfLines = 0
            label.frame = CGRect(x: 24, y: 180, width: 300, height: 200); controller.view.addSubview(label)
            window.rootViewController = controller
        }
        window.makeKeyAndVisible()
        if options.notificationResponse?.notification.request.identifier == CodeExpiryReminder.notificationID {
            OrbitExpiryNotifications.shared.openSetup()
        }
        openRefreshSetupIfNeeded()
        if let id = options.notificationResponse?.notification.request.content.userInfo["appletID"] as? String {
            UserDefaults.standard.set(id, forKey: "Orbit.openApplet")
        }
        openAppletIfNeeded()
        if let url = options.urlContexts.first?.url { openWidget(url) }
        #if DEBUG && targetEnvironment(simulator)
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--script-inbox-fixture"), ProcessInfo.processInfo.arguments.count > index + 1 {
            let id = ProcessInfo.processInfo.arguments[index + 1]
            let source = "/* orbit-applet\n{\"id\":\"" + id + "\",\"name\":\"Received Applet\",\"domains\":[]}\n*/\nmodule.exports.render=()=>({type:'text',text:'Approved received applet'});"
            try? applets?.receive([source], origin: "simulator-fixture")
        }
        #endif
    }
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { openWidget(url) }
    }
    private func openWidget(_ url: URL) {
        guard url.isFileURL else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try OrbitJavaScriptFile(url: url)
            DispatchQueue.main.async { self.reviewFile(file) }
        } catch {
            let alert = UIAlertController(title: "Import JavaScript", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            window?.rootViewController?.present(alert, animated: true)
        }
    }
    private func reviewFile(_ file: OrbitJavaScriptFile) {
        guard let root = window?.rootViewController as? OrbitMainTabController else { return }
        root.destinationIndex = file.kind == .applet ? 2 : 3
        (file.kind == .applet ? applets : widgets)?.review(file.script.source)
    }
    func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
        guard let tabs = tabBarController as? OrbitTabBarController else { return }
        OrbitDiagnostics.shared.record("screen", "tab_selected", ["tab": selectedTab.identifier])
        UserDefaults.standard.set(tabs.destinationIndex, forKey: "Orbit.selectedTab")
    }
    func openRefreshSetupIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "Orbit.openRefreshSetup"),
              let root = window?.rootViewController as? OrbitMainTabController else { return }
        root.dismiss(animated: false)
        root.openRefreshSetup()
        UserDefaults.standard.removeObject(forKey: "Orbit.openRefreshSetup")
    }
    func openAppletIfNeeded() {
        guard let id = UserDefaults.standard.string(forKey: "Orbit.openApplet"),
              let root = window?.rootViewController as? OrbitMainTabController else { return }
        root.dismiss(animated: false)
        root.destinationIndex = 2
        applets?.openApplet(id)
        UserDefaults.standard.removeObject(forKey: "Orbit.openApplet")
    }
    private var expirySync: Task<Void, Never>?
    private var readiness: Task<Void, Never>?
    private var scriptSync: Task<Void, Never>?
    private var diagnosticSync: Task<Void, Never>?
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !inertPreview else { return }
        OrbitDiagnostics.shared.record("lifecycle", "active")
        OrbitAppletBackground.shared.foreground()
        openAppletIfNeeded()
        widgets?.refreshInbox(); applets?.refreshInbox()
        diagnosticSync?.cancel()
        diagnosticSync = Task { [weak self] in
            while !Task.isCancelled {
                await self?.connection.syncDiagnostics()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        scriptSync?.cancel()
        scriptSync = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncScripts()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        openRefreshSetupIfNeeded()
        expirySync?.cancel()
        expirySync = Task {
            while !Task.isCancelled {
                await OrbitExpiryNotifications.shared.synchronize()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
        readiness?.cancel()
        readiness = Task { await connection.offerInstallWindow(seconds: 3600) }
        Task {
            if let readiness = try? await CodeRefreshEngine.shared.readiness() { _ = try? await connection.rpc("phone_setup_status", readiness) }
        }
    }
    private func syncScripts() async {
        guard !connection.pairingCode.isEmpty else { return }
        await connection.syncRoutes()
        let peer = connection.peerID
        for (method, controller) in [("applets", applets), ("widgets", widgets)] {
            do {
                guard let result = try await connection.rpc(method) as? [[String: String]], result.allSatisfy({ $0["source"] != nil }) else { throw CodeFailure("Couldn’t read Mac scripts.") }
                guard !Task.isCancelled, peer == connection.peerID else { return }
                try controller?.receive(result.compactMap { $0["source"] }, origin: peer)
            } catch { /* Keep the last received queue while the Mac is unavailable. */ }
        }
    }
    func sceneWillResignActive(_ scene: UIScene) { diagnosticSync?.cancel(); diagnosticSync = nil; scriptSync?.cancel(); scriptSync = nil; OrbitAppletBackground.shared.background() }
    func sceneDidEnterBackground(_ scene: UIScene) { OrbitDiagnostics.shared.record("lifecycle", "background"); expirySync?.cancel(); expirySync = nil; Task { await OrbitExpiryNotifications.shared.update() }; scriptSync?.cancel(); scriptSync = nil; readiness?.cancel(); readiness = nil; OrbitAppDelegate.requestWindow() }

}
@MainActor final class OrbitConnectionController: UITableViewController {
    let connection: OrbitPhoneConnection
    init(connection: OrbitPhoneConnection) { self.connection = connection; super.init(style: .insetGrouped); title = "Orbit Mac" }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.cellLayoutMarginsFollowReadableWidth = true
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 4 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Logs sync to your Mac while Orbit is open." + (connection.localID.isEmpty ? "" : "\n\nThis phone: " + connection.localID)
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = ["Connect a Mac", "Check Connection", "Authorize This Phone", "Forget Mac"][indexPath.row]
        if indexPath.row == 0 { cell.detailTextLabel?.text = connection.peerID == "unpaired" ? nil : "Connected Mac saved" }
        cell.accessoryType = .disclosureIndicator; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        OrbitDiagnostics.shared.record("action", "connection_action", ["row": String(indexPath.row)])
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
