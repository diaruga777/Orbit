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
    private var status: [String: Bool] = [:]
    private var reviewingSetup = false
    private let steps = [0, 1, 3, 4, 6]
    private let keys = ["account", "pairing", "certificate", "cache", "connection"]
    private var nextStep: Int? { keys.indices.first { status[keys[$0]] != true } }
    private var setupRows: [Int] { reviewingSetup || nextStep == nil ? Array(0..<8) : [steps[nextStep!]] }
    private var importKind = "ipa"
    public init(engine: CodeRefreshEngine = .shared) { self.engine = engine; super.init(style: .insetGrouped); title = "Refresh" }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Refresh All", style: .plain, target: self, action: #selector(refreshAll))
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Setup details", style: .plain, target: self, action: #selector(toggleSetup))
        reload()
    }
    @objc private func toggleSetup() {
        reviewingSetup.toggle()
        navigationItem.leftBarButtonItem?.title = reviewingSetup ? "Guided setup" : "Setup details"
        updateSetupHeader()
        tableView.reloadData()
    }
    public override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let size = header.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if abs(header.frame.height - size.height) > 0.5 || header.frame.width != tableView.bounds.width {
            header.frame.size = CGSize(width: tableView.bounds.width, height: size.height)
            tableView.tableHeaderView = header
        }
    }
    private func reload() {
        Task {
            do {
                apps = try await engine.apps()
                team = try await engine.account.team()?.name
                pairing = try await engine.device.hasPairing()
                certificate = try await engine.account.hasCertificate()
                status = (try? await engine.readiness()) ?? [:]
                updateSetupHeader()
                tableView.reloadData()
                if let status = try? await engine.readiness() { readinessChanged?(status) }
                NotificationCenter.default.post(name: .codeRefreshStateChanged, object: nil)
            } catch { message(error.localizedDescription) }
        }
    }
    private func updateSetupHeader() {
        guard let step = nextStep, !reviewingSetup else { tableView.tableHeaderView = nil; return }
        let detail = UILabel()
        detail.text = [
            "Sign in with the Apple Account that signs your apps.",
            "In Orbit Mac, choose Phone & Remote Setup and export the pairing file for this iPhone.",
            "Create a certificate for this iPhone, or import an existing .p12 file in Setup details.",
            "Cache the installed version of Orbit while your Mac is connected.",
            "Connect to Wi-Fi and turn on LocalDevVPN before checking the connection."
        ][step]
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0; detail.adjustsFontForContentSizeCategory = true
        let progress = UIProgressView(progressViewStyle: .default)
        progress.progress = Float(step) / Float(keys.count)
        progress.accessibilityLabel = "Setup progress"
        progress.accessibilityValue = "Step \(step + 1) of \(keys.count)"
        let stack = UIStackView(arrangedSubviews: [detail, progress])
        stack.axis = .vertical
        stack.spacing = 20
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 24, leading: 24, bottom: 24, trailing: 24)
        let width = tableView.bounds.width
        stack.frame = CGRect(origin: .zero, size: stack.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel))
        tableView.tableHeaderView = stack
    }
    public override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? setupRows.count : apps.count }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? (nextStep.map { "Step \($0 + 1) of 5" } ?? "Refresh settings") : "Cached Builds" }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 && (nextStep == nil || reviewingSetup) ? "Use Wi-Fi and LocalDevVPN to refresh. iOS schedules automatic refreshes. Open Orbit before your apps expire." : nil
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil); cell.accessoryType = .disclosureIndicator
        cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.directionalLayoutMargins = .init(top: 18, leading: 20, bottom: 18, trailing: 20)
        if indexPath.section == 0 {
            let row = setupRows[indexPath.row]
            cell.textLabel?.text = ["Apple Account", "Pairing File", "Signing Certificate", "Create Signing Certificate", "Cache Orbit", "Import Build", "Check Refresh Connection", "Sign Out"][row]
            cell.detailTextLabel?.text = [team ?? "Sign in", pairing ? "Saved on this phone" : "Import from your computer", certificate ? "Saved on this phone" : "Import a .p12 file", "Create a certificate for this phone", "Save Orbit so you can renew it away from your Mac", "Add an .ipa file", "Turn on LocalDevVPN, then tap to check", "Remove your saved Apple account"][row]
            if nextStep != nil && !reviewingSetup { cell.detailTextLabel?.text = nil }
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
        switch setupRows[indexPath.row] {
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
            do { try await operation() } catch { message(CodeRefreshAccountError.message(error)) }
        }
    }
    private func signIn() {
        Task {
            do {
                let server = try await engine.account.signInServer()
                let form = CodeRefreshSignInController(service: engine.account, server: server) { [weak self] in self?.reload() }
                let navigation = UINavigationController(rootViewController: form)
                navigation.modalPresentationStyle = .formSheet
                present(navigation, animated: true)
            } catch { message(error.localizedDescription) }
        }
    }
    private func pick(_ kind: String) {
        importKind = kind
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true); picker.delegate = self; present(picker, animated: true)
    }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let kind = importKind
        controller.dismiss(animated: true) { self.importDocument(url, kind: kind) }
    }
    private func importedData(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2 * 1024 * 1024 else {
            throw CodeFailure("This file is too large. Choose a pairing plist or signing .p12.")
        }
        return try Data(contentsOf: url)
    }
    private func importDocument(_ url: URL, kind: String) {
        if kind == "certificate" {
            let alert = UIAlertController(title: "Certificate Password", message: nil, preferredStyle: .alert)
            alert.addTextField { $0.isSecureTextEntry = true }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Import", style: .default) { _ in self.perform { try await self.engine.account.importCertificate(self.importedData(url), password: alert.textFields?.first?.text ?? "") } })
            present(alert, animated: true)
        } else { perform { if kind == "pairing" { try await self.engine.importPairing(self.importedData(url)) } else { try await self.engine.importIPA(url) } } }
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
        if UIApplication.shared.applicationState == .background { return }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        let alert = UIAlertController(title: "Ready to Refresh Orbit", message: "Go to the Home Screen to finish. Reopen Orbit after the update.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); top?.present(alert, animated: true)
        let deadline = Date().addingTimeInterval(90)
        while UIApplication.shared.applicationState != .background {
            try Task.checkCancellation()
            guard Date() < deadline else { throw CodeFailure("Go to the Home Screen when prompted, then try refreshing again.") }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}
#endif
