#if os(iOS)
import BackgroundTasks
import UserNotifications
#if canImport(OrbitWidgets)
import OrbitWidgets
#endif

/// Shared by Orbit and standalone hosts. No push entitlement or server is needed.
@MainActor public final class OrbitAppletBackground {
    public static let shared = OrbitAppletBackground()
    private let store = OrbitWidgetStore(applets: true)
    private let center = UNUserNotificationCenter.current()
    private var foregroundWork: Task<Void, Never>?
    // Standalone hosts restrict background execution to the approved bundled digest.
    public var allowedSource: ((String) -> Bool)?
    public private(set) var schedulingFailure: String?
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "org.example.orbit") + ".applet-poll" }
    public func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor in
                let work = Task { @MainActor in
                    let success = await self.checkAll()
                    await self.schedule()
                    task.setTaskCompleted(success: success && !Task.isCancelled)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
    }
    public func foreground() {
        foregroundWork?.cancel()
        foregroundWork = Task {
            await requestPermissionIfNeeded()
            while !Task.isCancelled {
                _ = await checkAll()
                await schedule()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
    public func background() {
        foregroundWork?.cancel(); foregroundWork = nil
        Task { await schedule() }
    }
    public func requestPermissionIfNeeded() async {
        guard let scripts = try? store.scripts(), scripts.contains(where: {
            (allowedSource?($0.source) ?? true) && (try? OrbitAppletDefinition.parse($0.source).notifications) == true
        }) else { return }
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }
    public func schedule() async {
        do {
            let scripts = try store.scripts().filter { allowedSource?($0.source) ?? true }
            guard scripts.contains(where: { (try? OrbitAppletDefinition.parse($0.source).pollHours) != nil }),
                  let next = try await OrbitAppletRunner.shared.nextCheck(store: store) else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier); return
            }
            let request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = max(next, Date().addingTimeInterval(60))
            try BGTaskScheduler.shared.submit(request)
            schedulingFailure = nil
        } catch { schedulingFailure = error.localizedDescription }
    }
    public func check(_ script: OrbitWidgetScript) async throws {
        guard allowedSource?(script.source) ?? true else { return }
        let center = self.center
        try await OrbitAppletRunner.shared.check(script: script, store: store) { notice in
            let settings = await center.notificationSettings()
            // Denied alerts are dropped; fetching and private state still work.
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title; content.body = notice.body; content.sound = .default
            content.userInfo = ["appletID": script.id]
            let id = "orbit.applet." + script.id + "." + OrbitWidgetDefinition.digest(notice.id)
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
    private func checkAll() async -> Bool {
        do {
            var success = true
            for script in try store.scripts() {
                try Task.checkCancellation()
                do { try await check(script) } catch { success = false }
            }
            return success
        } catch { return false }
    }
}
#endif
