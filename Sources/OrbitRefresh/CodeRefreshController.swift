#if os(iOS)
import UIKit
import UniformTypeIdentifiers
import BackgroundTasks
import SideSign
import OrbitCore

@MainActor public final class CodeRefreshController: UITableViewController, UIDocumentPickerDelegate {
    public var readinessChanged: (([String: Bool]) -> Void)?
    private let engine: CodeRefreshEngine
    private var apps: [CodeLocalRefreshApp] = []
    private var team: String?
    private var pairing = false
    private var certificate = false
    private var working = false
    private var work: Task<Void, Never>?
    private var importKind = "ipa"
    public init(engine: CodeRefreshEngine = .shared) { self.engine = engine; super.init(style: .insetGrouped); title = "Refresh" }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Refresh All", style: .plain, target: self, action: #selector(refreshAll))
        reload()
    }
    public override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }
    private func reload() {
        Task {
            do {
                apps = try await engine.apps()
                team = try await engine.account.team()?.name
                pairing = try await engine.device.hasPairing()
                certificate = try await engine.account.hasCertificate()
                tableView.reloadData()
                if let status = try? await engine.readiness() { readinessChanged?(status) }
                NotificationCenter.default.post(name: .codeRefreshStateChanged, object: nil)
            } catch { message(error.localizedDescription) }
        }
    }
    public override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 8 : apps.count }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? nil : "Cached Builds" }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "Connect to Wi-Fi and LocalDevVPN to refresh. iOS decides when automatic refresh can run; open Orbit before your apps expire." : nil
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil); cell.accessoryType = .disclosureIndicator
        cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            cell.textLabel?.text = ["Apple Account", "Pairing File", "Signing Certificate", "Create Signing Certificate", "Cache Orbit", "Import Build", "Check Refresh Connection", "Sign Out"][indexPath.row]
            cell.detailTextLabel?.text = [team ?? "Sign in", pairing ? "Saved on this phone" : "Import from your computer", certificate ? "Saved on this phone" : "Import a .p12 file", nil, nil, nil, nil, nil][indexPath.row]
        } else {
            let app = apps[indexPath.row]
            cell.textLabel?.text = app.name
            cell.detailTextLabel?.text = app.failure ?? (app.requiresReconciliation ? "Check installation" : "Expires " + app.expiresAt.formatted(date: .abbreviated, time: .shortened))
            if app.automatic { cell.detailTextLabel?.text = (cell.detailTextLabel?.text ?? "") + " · Automatic" }
        }
        return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !working else { return }
        if indexPath.section == 1 { choose(apps[indexPath.row]); return }
        switch indexPath.row {
        case 0: signIn()
        case 1: pick("pairing")
        case 2: pick("certificate")
        case 3:
            let alert = UIAlertController(title: "Create Signing Certificate?", message: "This uses a development certificate slot on your Apple account. Existing certificates will stay active.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Create", style: .default) { _ in self.perform { try await self.engine.account.createCertificate() } }); present(alert, animated: true)
        case 4: perform { try await self.engine.cacheSelf() }
        case 5: pick("ipa")
        case 6: perform { try await self.engine.verifyConnection(); self.message("Your refresh connection is ready.") }
        default: perform { try await self.engine.account.signOut() }
        }
    }
    private func choose(_ app: CodeLocalRefreshApp) {
        let alert = UIAlertController(title: app.name, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: app.requiresReconciliation ? "Check Installation" : "Refresh Now", style: .default) { _ in
            self.perform { if app.requiresReconciliation { try await self.engine.reconcile(id: app.id) } else { try await self.engine.refresh(id: app.id) } }
        })
        if app.requiresReconciliation {
            alert.addAction(UIAlertAction(title: "Clear Pending Attempt…", style: .destructive) { _ in
                let confirm = UIAlertController(title: "Clear This Attempt?", message: "Check that the app’s update has stopped. Its cached build will stay ready to retry.", preferredStyle: .alert)
                confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                confirm.addAction(UIAlertAction(title: "Clear Attempt", style: .destructive) { _ in self.perform { try await self.engine.clearPending(id: app.id) } })
                self.present(confirm, animated: true)
            })
        }
        alert.addAction(UIAlertAction(title: app.automatic ? "Turn Off Automatic Refresh" : "Turn On Automatic Refresh", style: .default) { _ in
            self.perform { try await self.engine.setAutomatic(id: app.id, enabled: !app.automatic); CodeRefreshBackground.schedule() }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.popoverPresentationController?.sourceView = tableView
        alert.popoverPresentationController?.sourceRect = tableView.rectForRow(at: IndexPath(row: apps.firstIndex(where: { $0.id == app.id }) ?? 0, section: 1))
        present(alert, animated: true)
    }
    @objc private func refreshAll() {
        perform {
            for app in try await self.engine.apps().sorted(by: { $0.bundleID != Bundle.main.bundleIdentifier && $1.bundleID == Bundle.main.bundleIdentifier }) {
                try Task.checkCancellation()
                try await self.engine.refresh(id: app.id)
            }
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }; working = true; navigationItem.rightBarButtonItem?.isEnabled = false
        let lease = UIApplication.shared.beginBackgroundTask(withName: "Refresh apps") { [weak self] in self?.work?.cancel() }
        work = Task {
            defer { if lease != .invalid { UIApplication.shared.endBackgroundTask(lease) }; working = false; work = nil; navigationItem.rightBarButtonItem?.isEnabled = true; reload() }
            do { try await operation() } catch { message(error.localizedDescription) }
        }
    }
    private func signIn() {
        let alert = UIAlertController(title: "Apple Account", message: "Apple handles sign-in. Remembering your password keeps it in this phone’s Keychain for automatic refresh. The anisette server doesn’t receive it.", preferredStyle: .alert)
        for placeholder in ["Apple account email", "Password", "Anisette server (https://…)"] {
            alert.addTextField { field in field.placeholder = placeholder; field.autocapitalizationType = .none; field.autocorrectionType = .no; field.isSecureTextEntry = placeholder == "Password" }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        for remember in [false, true] {
            alert.addAction(UIAlertAction(title: remember ? "Sign In and Remember" : "Sign In Once", style: .default) { _ in
                guard let fields = alert.textFields, let email = fields[0].text, let password = fields[1].text, let server = URL(string: fields[2].text ?? "") else { return }
                self.perform {
                    let teams = try await self.engine.account.signIn(appleID: email, password: password, anisetteURL: server, rememberPassword: remember) { [weak self] request in
                        guard let self else { return .cancel }
                        return try await self.verify(request)
                    }
                    self.selectTeam(teams)
                }
            })
        }
        present(alert, animated: true)
    }
    private func selectTeam(_ teams: [Team]) {
        let alert = UIAlertController(title: "Apple Team", message: nil, preferredStyle: .actionSheet)
        for team in teams { alert.addAction(UIAlertAction(title: team.name, style: .default) { _ in self.perform { try await self.engine.account.select(team) } }) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        alert.popoverPresentationController?.permittedArrowDirections = []
        present(alert, animated: true)
    }
    private func verify(_ request: TwoFactorRequest) async throws -> TwoFactorResponse {
        switch request {
        case .selectDeliveryMethod(_, let phones):
            return await withCheckedContinuation { continuation in
                let alert = UIAlertController(title: "Send Verification Code", message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Apple Devices", style: .default) { _ in continuation.resume(returning: .requestTrustedDevice) })
                for phone in phones { alert.addAction(UIAlertAction(title: phone.number, style: .default) { _ in continuation.resume(returning: .requestSMS(phoneID: phone.id)) }) }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: .cancel) })
                present(alert, animated: true)
            }
        default: break
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: "Verification Code", message: request.error ?? "Enter the code from Apple.", preferredStyle: .alert)
            alert.addTextField { $0.keyboardType = .numberPad; $0.textContentType = .oneTimeCode }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: .cancel) })
            alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in continuation.resume(returning: .verificationCode(alert.textFields?.first?.text ?? "")) })
            present(alert, animated: true)
        }
    }
    private func pick(_ kind: String) {
        importKind = kind
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true); picker.delegate = self; present(picker, animated: true)
    }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let kind = importKind
        if kind == "certificate" {
            let alert = UIAlertController(title: "Certificate Password", message: nil, preferredStyle: .alert)
            alert.addTextField { $0.isSecureTextEntry = true }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Import", style: .default) { _ in self.perform { try await self.engine.account.importCertificate(Data(contentsOf: url), password: alert.textFields?.first?.text ?? "") } })
            present(alert, animated: true)
        } else { perform { if kind == "pairing" { try await self.engine.device.importPairing(Data(contentsOf: url)) } else { try await self.engine.importIPA(url) } } }
    }
    private func message(_ text: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Refresh", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}

@MainActor public enum CodeRefreshBackground {
    private static var identifier: String { (Bundle.main.bundleIdentifier ?? "Orbit") + ".refresh-builds" }
    public static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task {
                let success = await CodeRefreshEngine.shared.refreshDue()
                task.setTaskCompleted(success: success && !Task.isCancelled)
                schedule()
            }
            task.expirationHandler = { work.cancel() }
        }
        schedule()
    }
    public static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true; request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@MainActor enum CodeRefreshLifecycle {
    static func waitForBackground() async throws {
        if UIApplication.shared.applicationState != .active { return }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        let alert = UIAlertController(title: "Ready to Refresh Orbit", message: "Go to the Home Screen to finish. Reopen Orbit after the update.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); top?.present(alert, animated: true)
        let deadline = Date().addingTimeInterval(90)
        while UIApplication.shared.applicationState == .active {
            try Task.checkCancellation()
            guard Date() < deadline else { throw CodeFailure("Go to the Home Screen when prompted, then try refreshing again.") }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}
#endif
