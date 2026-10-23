import UIKit
import UserNotifications
import OrbitCore
import OrbitRefresh

/// One OS-owned reminder works while Orbit and the Mac are closed.
@MainActor final class OrbitExpiryNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OrbitExpiryNotifications()
    private let center = UNUserNotificationCenter.current()
    private var updating = false
    private var updateAgain = false
    private var receipt: CodeInstalledApp? {
        try? JSONDecoder().decode(CodeInstalledApp.self, from: Data(contentsOf:
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(CodeInstalledApp.phoneReceiptPath)))
    }
    private var deviceID: String? {
        receipt?.deviceID ?? UserDefaults.standard.string(forKey: "Orbit.expiryDeviceID")
    }
    func start() {
        center.delegate = self
        NotificationCenter.default.addObserver(forName: .codeRefreshStateChanged, object: nil, queue: .main) { _ in
            Task { await Self.shared.update() }
        }
    }
    func synchronize() async {
        await update()
        let connection = OrbitPhoneConnection.shared
        // Existing authorization can identify phones installed outside the wizard.
        if deviceID == nil, let bundle = Bundle.main.bundleIdentifier,
           let identity = try? CodeInstallEndpointIdentity(service: bundle + ".installation"),
           let bindings = try? await connection.client.call(CodeRequest(.endpointStatus)).endpointBindings,
           let binding = bindings.first(where: { $0.publicKey == identity.publicKey }) {
            UserDefaults.standard.set(binding.deviceID, forKey: "Orbit.expiryDeviceID")
        }
        if let deviceID, let result = try? await connection.rpc("installed_apps", ["deviceID": deviceID]),
           let data = try? JSONSerialization.data(withJSONObject: result),
           let apps = try? JSONDecoder().decode([CodeInstalledApp].self, from: data),
           let store = try? CodeInstalledAppStore(root: OrbitPhoneConnection.root.appendingPathComponent("Expiry")) {
            try? store.replace(deviceID: deviceID, with: apps)
        }
        await update()
    }
    func update() async {
        if updating { updateAgain = true; return }
        updating = true
        defer {
            updating = false
            if updateAgain { updateAgain = false; Task { await self.update() } }
        }
        let engine = CodeRefreshEngine.shared
        // A disconnected VPN is transient; configured credentials/cache determine
        // setup completion, without repeatedly asking after a completed setup.
        let readiness = (try? await engine.readiness()) ?? [:]
        let complete = ["cache", "account", "certificate", "pairing"].allSatisfy { readiness[$0] == true }
        let id = deviceID ?? "this-phone"
        var apps = ((try? CodeInstalledAppStore(root: OrbitPhoneConnection.root.appendingPathComponent("Expiry")).apps()) ?? []).filter { $0.deviceID == id }
        if let own = try? await engine.installedSelf(deviceID: id, receipt: receipt) { apps.append(own) }
        for app in (try? await engine.apps()) ?? [] {
            guard let date = app.lastConfirmed else { continue } // Importing an IPA is not an install.
            apps.append(CodeInstalledApp(deviceID: id, bundleID: app.bundleID, name: app.name,
                version: app.version, build: app.build, installedAt: date, profileExpiresAt: app.expiresAt))
        }
        let now = Date()
        let plan = CodeExpiryReminder.next(apps: CodeExpiryReminder.latest(apps), setupComplete: complete, at: now)
        let pending = await center.pendingNotificationRequests()
        let current = pending.first { $0.identifier == CodeExpiryReminder.notificationID }
        guard let plan else {
            center.removePendingNotificationRequests(withIdentifiers: [CodeExpiryReminder.notificationID])
            center.removeDeliveredNotifications(withIdentifiers: [CodeExpiryReminder.notificationID])
            if complete { UserDefaults.standard.removeObject(forKey: "Orbit.lastExpiryReminder") }
            return
        }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            // Only prompt once there is an installed app to protect, in foreground.
            guard UIApplication.shared.applicationState == .active,
                  (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        } else if ![.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) { return }
        if current?.content.userInfo["expiryKey"] as? String == plan.key { return }
        if current == nil, UserDefaults.standard.string(forKey: "Orbit.lastExpiryReminder") == plan.key { return }
        let content = UNMutableNotificationContent()
        content.title = "Finish phone-only refresh"
        content.body = "\(plan.app.name) expires soon. Finish setup to refresh your apps without your Mac."
        content.sound = .default
        content.userInfo = ["destination": "refresh-setup", "expiryKey": plan.key]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, plan.scheduledAt.timeIntervalSince(now)), repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: CodeExpiryReminder.notificationID, content: content, trigger: trigger))
            UserDefaults.standard.set(plan.key, forKey: "Orbit.lastExpiryReminder")
        } catch { NSLog("Orbit expiry reminder: %@", error.localizedDescription) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == CodeExpiryReminder.notificationID,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { self.openSetup() }
    }
    func openSetup() {
        UserDefaults.standard.set(true, forKey: "Orbit.openRefreshSetup")
        for scene in UIApplication.shared.connectedScenes {
            (scene.delegate as? OrbitSceneDelegate)?.openRefreshSetupIfNeeded()
        }
    }
}
