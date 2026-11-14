import UIKit
import OrbitCore
import OrbitRefresh
import OrbitWire

/// Setup completion is independent of transient Mac/VPN reachability.
@MainActor final class OrbitSettingsController: UITableViewController {
    var badgeChanged: ((Bool) -> Void)?
    var setupStatus: () async -> (refresh: Bool, remote: Bool)
    private let connection: OrbitPhoneConnection
    private let refreshController: CodeRefreshController
    private var status = (refresh: false, remote: false)
    private var statusTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(connection: OrbitPhoneConnection, refreshController: CodeRefreshController) {
        self.connection = connection
        self.refreshController = refreshController
        setupStatus = {
            let refresh = (try? await CodeRefreshEngine.shared.setupComplete()) ?? false
            let remote = OrbitConnectionRoutes.hasRemoteConnection(pairingCode: connection.pairingCode, savedRoutes: connection.savedRoutes)
            return (refresh, remote)
        }
        super.init(style: .insetGrouped)
        title = "More"
        for name in [Notification.Name.codeRefreshStateChanged, UserDefaults.didChangeNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateStatus() }
            })
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); statusTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        updateStatus()
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); updateStatus() }

    func updateStatus() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            guard let self else { return }
            let updated = await setupStatus()
            guard !Task.isCancelled else { return }
            status = updated
            badgeChanged?(!status.refresh || !status.remote)
            if isViewLoaded { tableView.reloadData() }
        }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Take Orbit with you" : "Connection" }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.accessoryType = .disclosureIndicator
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        if indexPath.section == 1 {
            cell.textLabel?.text = "Mac"
            cell.detailTextLabel?.text = connection.connectionName ?? "Connect and manage your Mac"
            cell.imageView?.image = UIImage(systemName: "desktopcomputer")
            cell.accessibilityIdentifier = "settings.mac"
        } else {
            let refresh = indexPath.row == 0
            let complete = refresh ? status.refresh : status.remote
            cell.textLabel?.text = refresh ? "Phone-only refresh" : "Remote builds"
            cell.detailTextLabel?.text = complete ? "Ready" : (refresh ? "Refresh without your Mac" : "Build away from home")
            cell.imageView?.image = UIImage(systemName: refresh ? "arrow.clockwise" : "network")
            cell.accessibilityIdentifier = refresh ? "settings.refresh" : "settings.remote"
            cell.accessibilityValue = complete ? "Ready" : "Setup needed"
            if !complete {
                let badge = UILabel()
                badge.text = "!"
                badge.font = .preferredFont(forTextStyle: .headline)
                badge.textColor = .white
                badge.backgroundColor = .systemRed
                badge.textAlignment = .center
                badge.layer.cornerRadius = 11
                badge.clipsToBounds = true
                badge.frame.size = CGSize(width: 22, height: 22)
                badge.isAccessibilityElement = false
                cell.accessoryView = badge
            }
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 { openMac() }
        else if indexPath.row == 0 { openRefreshSetup() }
        else { showRemoteSetup() }
    }
    func openRefreshSetup() {
        navigationController?.setViewControllers([self, refreshController], animated: false)
        refreshController.loadViewIfNeeded()
        refreshController.tableView.setContentOffset(.zero, animated: false)
    }
    private func openMac() {
        navigationController?.pushViewController(OrbitConnectionController(connection: connection), animated: true)
    }
    private func showRemoteSetup() {
        let message = status.remote
            ? "Remote connections are set up. \(connection.connectionName.map { "Saved connection: \($0). " } ?? "")To switch, open Orbit Mac → Settings."
            : "Choose Automatic (iroh), Tailscale, or a private relay in Orbit Mac → Settings. Keep Orbit open on this iPhone to sync the change."
        let alert = UIAlertController(title: "Build away from home", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Mac Settings", style: .default) { [weak self] _ in self?.openMac() })
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        present(alert, animated: true)
    }
}
