#if os(iOS)
import UIKit
import OrbitCore

@MainActor public final class CodeOvernightSettingsController: UITableViewController {
    private let client: CodeClient
    private let peerID: () -> String
    private var remote: [CodeOvernightJob]?
    private var capabilities: CodeOvernightCapabilities?
    private var message: String?
    private var refreshing = false
    private var timer: Timer?
    private var journal: CodeOvernightStore? { CodeNightlyScheduler.shared.journal }
    private var invocations: [CodeOvernightInvocation] { (journal?.invocations() ?? []).filter { $0.peerID == peerID() }.sorted { $0.startedAt > $1.startedAt } }
    private var jobs: [CodeOvernightJob] { (journal?.jobs() ?? []).filter { $0.target.peerID == peerID() }.sorted { $0.acceptedAt > $1.acceptedAt } }
    public init(client: CodeClient, peerID: @escaping () -> String) {
        self.client = client; self.peerID = peerID; super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad(); title = "Overnight Builds"
        tableView.rowHeight = UITableView.automaticDimension
        refreshControl = UIRefreshControl(); refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
    }
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); tableView.reloadData()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.tableView.reloadData() } }
    }
    public override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); timer?.invalidate(); timer = nil }
    public override func numberOfSections(in tableView: UITableView) -> Int { 5 }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section { case 0: return 5; case 1: return 4; case 2: return 3; case 3: return max(1, invocations.count); default: return max(1, jobs.count) }
    }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [nil, nil, "Mac Connection", "Recent Attempts", "Mac Jobs"][section]
    }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 1 { return message }
        if section == 2 { return "iOS chooses when background work runs. Remote installation needs an authorized phone while Orbit can run. Updating Orbit itself needs an independent Apple device connection." }
        return nil
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.detailTextLabel?.numberOfLines = 0; cell.textLabel?.numberOfLines = 0
        switch indexPath.section {
        case 0:
            let latest = invocations.first
            switch indexPath.row {
            case 0: cell.textLabel?.text = "Last Attempt"; cell.detailTextLabel?.text = latest.map { "\(format($0.startedAt)) · \(label($0.state.rawValue))" } ?? "No recorded attempt"
            case 1: cell.textLabel?.text = "Last Build"; cell.detailTextLabel?.text = format(jobs.compactMap(\.builtAt).max())
            case 2: cell.textLabel?.text = "Last Confirmed Installation"; cell.detailTextLabel?.text = format(jobs.compactMap(\.installedAt).max())
            case 3: cell.textLabel?.text = "Next Requested Attempt"; cell.detailTextLabel?.text = format(CodeNightlyScheduler.shared.nextRequestedAt)
            default: cell.textLabel?.text = "Status Updated"; cell.detailTextLabel?.text = format(jobs.compactMap(\.synchronizedAt).max()) + (remote == nil ? " · Last known status" : "")
            }
            cell.selectionStyle = .none
        case 1:
            cell.textLabel?.text = ["Try Now", "Refresh Status", "Export Diagnostics", "Authorize This Phone"][indexPath.row]
            cell.textLabel?.textColor = .tintColor
        case 2:
            let policy = CodeNightlyScheduler.shared.policy(peer: peerID())
            cell.textLabel?.text = ["Local", "Tailscale", "Syncthing Relay"][indexPath.row]
            let provider: CodeInstallProvider = [.local, .tailscale, .syncthing][indexPath.row]
            cell.detailTextLabel?.text = provider == .local ? "Always tried first" : (policy.remoteProviders.contains(provider) ? "Configured" : "Off")
            cell.accessoryType = provider == .local ? .none : .disclosureIndicator
        case 3:
            if invocations.isEmpty { cell.textLabel?.text = "No recorded attempt" }
            else {
                let attempt = invocations[indexPath.row]
                cell.textLabel?.text = "\(format(attempt.startedAt)) · \(label(attempt.state.rawValue))"
                cell.detailTextLabel?.text = attempt.error.map { $0.stage + ": " + $0.recovery } ?? attempt.reason.capitalized
            }
        default:
            if jobs.isEmpty { cell.textLabel?.text = "No recorded Mac job" }
            else {
                let job = jobs[indexPath.row]
                cell.textLabel?.text = job.target.project.scheme + " · " + label(job.state.rawValue)
                cell.detailTextLabel?.text = [job.error?.recovery, job.artifact.map { "Build \($0.build) · \($0.commit.prefix(8))" }, job.installs.last?.connectionDescription].compactMap { $0 }.joined(separator: "\n")
                cell.accessoryType = .disclosureIndicator
            }
        }
        return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (indexPath.section, indexPath.row) {
        case (1, 0): CodeNightlyScheduler.shared.tryNow(); tableView.reloadData()
        case (1, 1): refresh()
        case (1, 2): export()
        case (1, 3): CodePhoneAuthorization.choose(client: client, from: self) { [weak self] result in
            self?.message = result; self?.tableView.reloadData()
        }
        case (2, 1): configure(.tailscale)
        case (2, 2): configure(.syncthing)
        case (4, _) where !jobs.isEmpty: show(jobs[indexPath.row])
        default: break
        }
    }
    @objc private func refresh() {
        guard !refreshing, let journal else { refreshControl?.endRefreshing(); return }; refreshing = true
        Task {
            defer { refreshing = false; refreshControl?.endRefreshing(); tableView.reloadData() }
            do {
                capabilities = try await client.call(CodeRequest(.overnightCapabilities)).overnightCapabilities
                let runner = CodeOvernightCoordinator(catalog: CodeBuildCatalog(defaults: .standard), client: client, journal: journal)
                remote = try await runner.refresh(); message = nil
            } catch { remote = nil; message = error.localizedDescription }
        }
    }
    private func configure(_ provider: CodeInstallProvider) {
        let peer = peerID(); var policy = CodeNightlyScheduler.shared.policy(peer: peer)
        let alert = UIAlertController(title: provider == .tailscale ? "Tailscale Address" : "Syncthing Relay", message: provider == .tailscale ? "Use your Mac’s tcp:// address. Tailscale must be connected on both devices." : "Use the same relay:// address configured on Orbit Mac. Public relays can see peer identifiers, timing and traffic sizes. A private relay works too.", preferredStyle: .alert)
        alert.addTextField { field in field.text = provider == .tailscale ? policy.tailscaleAddress : policy.relayAddress; field.autocapitalizationType = .none; field.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text), url.scheme == (provider == .tailscale ? "tcp" : "relay"), url.host != nil, url.user == nil, url.password == nil else {
                self?.message = "Enter a valid address."; self?.tableView.reloadData(); return
            }
            if provider == .tailscale { policy.tailscaleAddress = text } else { policy.relayAddress = text }
            if !policy.remoteProviders.contains(provider) { policy.remoteProviders.append(provider) }
            CodeNightlyScheduler.shared.setPolicy(policy, peer: peer); self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Turn Off", style: .destructive) { [weak self] _ in
            policy.remoteProviders.removeAll { $0 == provider }; CodeNightlyScheduler.shared.setPolicy(policy, peer: peer); self?.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    private func show(_ job: CodeOvernightJob) {
        let alert = UIAlertController(title: job.target.project.scheme, message: "\(label(job.state.rawValue))\n\(job.error?.recovery ?? "")", preferredStyle: .actionSheet)
        if job.artifact != nil {
            alert.addAction(UIAlertAction(title: "Retry Installation", style: .default) { [weak self] _ in self?.operation(.overnightInstall, job: job) })
        }
        if [.accepted, .building, .waitingForPhone, .installing, .unknownCompletion].contains(job.state) {
            alert.addAction(UIAlertAction(title: "Cancel Job", style: .destructive) { [weak self] _ in self?.operation(.overnightCancel, job: job) })
        }
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        alert.popoverPresentationController?.sourceView = view; present(alert, animated: true)
    }
    private func operation(_ operation: CodeRequest.Operation, job: CodeOvernightJob) {
        Task {
            do {
                var request = CodeRequest(operation); request.jobID = job.id
                for job in try await client.call(request).overnightJobs ?? [] { try journal?.save(job) }
            } catch { message = error.localizedDescription }
            tableView.reloadData()
        }
    }
    private func export() {
        Task {
        // Failure to fetch remote logs must not prevent exporting local evidence.
        let macFiles = try? await client.call(CodeRequest(.overnightDiagnostics)).overnightDiagnostics
        do {
            guard let directory = try journal?.export(remote: remote, capabilities: capabilities, macFiles: macFiles) else { throw CodeFailure("Attempt history is unavailable.") }
            // Share files, not an ephemeral archive tied to the current connection.
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let controller = UIActivityViewController(activityItems: files, applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = view; present(controller, animated: true)
        } catch { message = error.localizedDescription; tableView.reloadData() }
        }
    }
    private func format(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "None recorded" }
    private func label(_ value: String) -> String {
        switch value {
        case "waitingForPhone": return "Waiting for Phone"
        case "unknownCompletion": return "Needs Confirmation"
        case "accepted": return "Accepted by Mac"
        case "succeeded": return "Completed"
        default: return value.capitalized
        }
    }
}
#endif
