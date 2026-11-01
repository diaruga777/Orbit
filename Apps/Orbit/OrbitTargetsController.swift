import UIKit
import OrbitCore
import OrbitRefresh
import OrbitUI
import OrbitTransport

@MainActor final class OrbitTargetsController: UITableViewController, UISearchResultsUpdating {
    private let rpc: (String, [String: Any]) async throws -> Any
    private let monitor: CodeBuildMonitor?
    private let peerID: () -> String
    private let preparePhoneInstall: () async throws -> Void
    private var checkingNetwork = false
    private let refreshInterval: TimeInterval
    private var macUpdate: [String: Any] = [:]
    private var startingMacUpdate = false
    private var jobs: [String: CodeJob] = [:]
    private var starting: String?
    private var poll: Timer?
    private var refreshing = false
    private var listMessage: String? = "Loading apps…"
    private var loaded = false
    private var peer = ""
    private var apps: [[String: Any]] = []
    private var repositories: [[String: Any]] = []
    private var searchTask: Task<Void, Never>?
    private let search = UISearchController(searchResultsController: nil)
    convenience init(connection: OrbitPhoneConnection, monitor: CodeBuildMonitor) {
        self.init(rpc: { method, params in try await connection.rpc(method, params) }, monitor: monitor, peerID: { connection.peerID })
    }
    init(rpc: @escaping (String, [String: Any]) async throws -> Any, monitor: CodeBuildMonitor? = nil, peerID: @escaping () -> String = { "preview" }, refreshInterval: TimeInterval = 3, preparePhoneInstall: @escaping () async throws -> Void = { try await OrbitInstallNetwork.requireWiFi() }) {
        self.preparePhoneInstall = preparePhoneInstall; self.refreshInterval = refreshInterval; self.monitor = monitor; self.peerID = peerID; self.rpc = rpc; super.init(style: .insetGrouped); title = "Apps"
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { poll?.invalidate(); searchTask?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad(); OrbitDiagnostics.shared.record("screen", "apps_loaded"); tableView.cellLayoutMarginsFollowReadableWidth = true; search.searchResultsUpdater = self; search.searchBar.placeholder = "Search GitHub"
        navigationItem.searchController = search
        tableView.accessibilityIdentifier = "OrbitTargets"
        if let monitor { NotificationCenter.default.addObserver(self, selector: #selector(buildChanged), name: CodeBuildMonitor.changed, object: monitor) }
        poll = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active else { return }
                await self.refreshTargets(showError: false)
            }
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.detectProjects() })
        refreshControl = UIRefreshControl(); refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); refresh() }
    @objc private func refresh() {
        OrbitDiagnostics.shared.record("action", "apps_refresh")
        Task { await refreshTargets(showError: true) }
    }
    private func updateListMessage() {
        // Empty/error messaging belongs to Apps; keep the Mac section visible.
        tableView.backgroundView = nil
    }

    private func refreshTargets(showError: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        if !loaded { listMessage = "Loading apps…" }
        updateListMessage()
        defer { refreshing = false; refreshControl?.endRefreshing(); updateListMessage() }
        let origin = peerID()
        if peer != origin { peer = origin; jobs = [:]; apps = []; macUpdate = [:]; startingMacUpdate = false; starting = nil; loaded = false; tableView.reloadData() }
        do {
            let value = try await rpc("mac_update_status", [:]) as? [String: Any] ?? [:]
            if origin == peerID() { macUpdate = value; tableView.reloadData() }
        } catch {
            if origin == peerID(), macBusy { macUpdate["stage"] = "Reconnecting to Orbit Mac…" }
        }
        do {
            guard let rows = try await rpc("targets", [:]) as? [[String: Any]], rows.allSatisfy({ $0["id"] is String && $0["name"] is String }) else { throw CodeFailure("Your Mac sent an invalid app list. Update Orbit Mac and retry.") }
            guard origin == peerID() else { return }
            apps = rows; loaded = true; listMessage = nil; tableView.reloadData(); updateListMessage()
            OrbitDiagnostics.shared.record("apps", "loaded", ["count": String(rows.count)])
            for row in rows {
                guard let id = (row["jobID"] ?? row["lastJobID"]) as? String else { continue }
                if jobs[id]?.state != .running, jobs[id] != nil { continue }
                do {
                    let value = try await fetchJob(id)
                    guard origin == peerID() else { return }
                    jobs[id] = value; monitor?.observe(value)
                } catch { OrbitDiagnostics.shared.error("apps", "job_failed", error, ["job": id]) }
            }
            tableView.reloadData()
        } catch {
            guard origin == peerID() else { return }
            listMessage = error.localizedDescription
            OrbitDiagnostics.shared.error("apps", "load_failed", error)
            if showError, !apps.isEmpty, presentedViewController == nil { show(error.localizedDescription) }
        }
    }
    private func fetchJob(_ id: String) async throws -> CodeJob {
        try CodeJob.targetStatus(JSONSerialization.data(withJSONObject: await rpc("job", ["id": id])))
    }
    @objc private func buildChanged() {
        if let job = monitor?.job { jobs[job.id] = job }
        guard !searching else { return }
        for cell in tableView.visibleCells {
            guard let index = tableView.indexPath(for: cell), index.section == 1, apps.indices.contains(index.row) else { continue }
            configure(cell, row: apps[index.row])
        }
        tableView.beginUpdates(); tableView.endUpdates()
    }
    private func build(_ row: [String: Any]) {
        guard !checkingNetwork, let monitor, let id = row["id"] as? String else { return }
        let origin = peerID()
        OrbitDiagnostics.shared.record("action", "build_pressed", ["target": id])
        checkingNetwork = true
        Task {
            var began = false
            defer {
                checkingNetwork = false
                if began, origin == peerID() { starting = nil; monitor.endStarting(peer: origin); buildChanged() }
            }
            do {
                try await preparePhoneInstall()
                guard origin == peerID(), UIApplication.shared.applicationState == .active else { return }
                try monitor.begin(title: "Build & Install · " + (row["name"] as? String ?? "App"))
                began = true; starting = id; buildChanged()
                let result = try await rpc("build", ["id": id, "monitorBundleID": Bundle.main.bundleIdentifier ?? ""])
                let job = try CodeJob.targetStatus(JSONSerialization.data(withJSONObject: result))
                OrbitDiagnostics.shared.record("build", "accepted", ["target": id, "job": job.id])
                guard origin == peerID() else { return }
                if let index = apps.firstIndex(where: { $0["id"] as? String == id }) { apps[index]["jobID"] = job.id }
                jobs[job.id] = job; monitor.accept(job)
                monitor.show(job, from: self)
            } catch {
                if origin == peerID() {
                    let alert = UIAlertController(title: error is OrbitInstallNetwork.WiFiRequired ? "Wi-Fi Needed" : "Apps", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
                }
            }
        }
    }
    func updateSearchResults(for searchController: UISearchController) {
        searchTask?.cancel()
        let query = searchController.searchBar.text ?? ""
        updateListMessage()
        guard !query.isEmpty else { repositories = []; tableView.reloadData(); return }
        searchTask = Task { do { try await Task.sleep(for: .milliseconds(400)); let rows = try await rpc("repo_search", ["query": query]) as? [[String: Any]] ?? []; guard !Task.isCancelled else { return }; repositories = rows; tableView.reloadData() } catch is CancellationError { } catch { show(error.localizedDescription) } }
    }
    private var searching: Bool { !(search.searchBar.text ?? "").isEmpty }
    private var macBusy: Bool { startingMacUpdate || ["accepted", "building", "installing", "restarting", "installed"].contains(macUpdate["state"] as? String ?? "") }
    override func numberOfSections(in tableView: UITableView) -> Int { searching ? 1 : 2 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { searching ? nil : section == 0 ? "Orbit Mac" : "Apps" }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { searching ? repositories.count : section == 0 ? 1 : max(1, apps.count) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if !searching, indexPath.section == 0 {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.text = macBusy ? "Updating Orbit Mac…" : "Rebuild Orbit Mac"
            cell.detailTextLabel?.text = macUpdate["failure"] as? String ?? macUpdate["stage"] as? String ?? "Update Orbit Mac from Xcode once to enable this."
            cell.detailTextLabel?.numberOfLines = 0
            cell.imageView?.image = UIImage(systemName: "desktopcomputer")
            let button = UIButton(type: .system)
            button.configuration = .tinted(); button.setImage(UIImage(systemName: "arrow.triangle.2.circlepath"), for: .normal)
            button.configuration?.showsActivityIndicator = macBusy
            button.isEnabled = !macBusy && macUpdate["available"] as? Bool == true
            button.accessibilityLabel = "Rebuild Orbit Mac"; button.accessibilityIdentifier = "OrbitMacRebuild"
            button.addAction(UIAction { [weak self] _ in self?.rebuildMac() }, for: .touchUpInside)
            button.sizeToFit(); cell.accessoryView = button
            cell.accessibilityIdentifier = "OrbitMacUpdate"
            return cell
        }
        if !searching, apps.isEmpty {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.text = listMessage ?? "No apps yet. Tap + to add one from your Mac."
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.accessibilityIdentifier = "OrbitTargetsMessage"
            if listMessage != nil {
                let retry = UIButton(type: .system); retry.setTitle("Retry", for: .normal)
                retry.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .touchUpInside)
                retry.sizeToFit(); cell.accessoryView = retry
            }
            return cell
        }
        let cell = searching ? UITableViewCell(style: .subtitle, reuseIdentifier: nil) : OrbitTargetCell()
        let row = searching ? repositories[indexPath.row] : apps[indexPath.row]
        if searching {
            var content = cell.defaultContentConfiguration()
            content.text = row["repository"] as? String; content.secondaryText = row["description"] as? String
            cell.contentConfiguration = content
        } else { configure(cell, row: row) }
        cell.accessoryType = .disclosureIndicator; return cell
    }
    private func rebuildMac() {
        guard !macBusy else { return }
        let origin = peerID()
        startingMacUpdate = true; tableView.reloadData()
        Task {
            defer { if origin == peerID() { startingMacUpdate = false; tableView.reloadData() } }
            do {
                let result = try await rpc("mac_update", [:]) as? [String: Any] ?? [:]
                if origin == peerID() { macUpdate = result }
            } catch {
                if origin == peerID() { show("Couldn’t confirm the update request. Check Mac update progress before trying again.\n\n" + error.localizedDescription) }
            }
        }
    }
    private func configure(_ cell: UITableViewCell, row: [String: Any]) {
        let id = row["id"] as? String ?? ""
        let job = ((row["jobID"] ?? row["lastJobID"]) as? String).flatMap { jobs[$0] }
        let busy = starting == id || job?.state == .running
        let fraction = starting == id ? monitor?.fraction ?? 0 : job.map { monitor?.fraction(for: $0) ?? $0.progressFraction() } ?? 0
        guard let cell = cell as? OrbitTargetCell else { return }
        cell.name.text = row["name"] as? String
        cell.play.accessibilityIdentifier = "OrbitTargetPlay:" + id
        cell.play.accessibilityLabel = "Build and install " + (row["name"] as? String ?? "app")
        cell.play.isEnabled = monitor != nil && !busy && monitor?.isStarting != true && monitor?.job?.state != .running
        cell.play.removeAction(identifiedBy: UIAction.Identifier("play"), for: .touchUpInside)
        cell.play.addAction(UIAction(identifier: UIAction.Identifier("play")) { [weak self] _ in self?.build(row) }, for: .touchUpInside)
        let schedule = (row["enabled"] as? Bool == true) ? "Refreshes every \(row["intervalHours"] ?? 144) hours" : "Manual builds"
        let status: String?
        if starting == id { status = "Starting on your Mac…" }
        else if let job {
            status = job.state == .running
                ? "\(Int(fraction * 100))% estimated · " + job.progressStage + (job.progressDetail.map { "\n" + $0 } ?? "") + "\n" + (monitor?.backgroundMessage ?? "")
                : job.state == .succeeded ? "Installed on your phone" : job.failureMessage ?? "Build " + job.state.rawValue
        } else { status = row["failure"] as? String }
        cell.detail.text = [schedule, status].compactMap { $0 }.joined(separator: "\n")
        cell.icon.image = (row["iconPNG"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) } ?? UIImage(systemName: "app.dashed")
        cell.accessibilityIdentifier = "OrbitTarget:" + id
        cell.progress.isHidden = !busy; cell.progress.progress = Float(fraction)
        cell.progress.accessibilityIdentifier = "OrbitTargetProgress:" + id
        cell.progress.accessibilityValue = "\(Int(fraction * 100)) percent estimated"
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if !searching, indexPath.section == 0 {
            let alert = UIAlertController(title: "Orbit Mac Update", message: macUpdate["log"] as? String ?? macUpdate["stage"] as? String, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Done", style: .cancel)); present(alert, animated: true)
            return
        }
        if !searching, apps.isEmpty { refresh(); return }
        if searching {
            let repository = repositories[indexPath.row]["repository"] as? String ?? ""
            Task { do {
                let info = try await rpc("repo_inspect", ["repository": repository]) as? [String: Any] ?? [:]
                guard info["compatible"] as? Bool == true else { show("This repository has no Xcode project."); return }
                let projects = info["projects"] as? [String] ?? []
                let alert = UIAlertController(title: repository, message: "Choose an Xcode project.", preferredStyle: .actionSheet)
                for project in projects { alert.addAction(UIAlertAction(title: project, style: .default) { _ in self.add(repository: repository, project: project) }) }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.popoverPresentationController?.sourceView = tableView; alert.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath); present(alert, animated: true)
            } catch { show(error.localizedDescription) } }
        } else {
            let app = apps[indexPath.row], id = app["id"] as? String ?? ""
            let alert = UIAlertController(title: app["name"] as? String, message: nil, preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "Build and Install", style: .default) { _ in self.build(app) })
            if let jobID = app["jobID"] as? String, jobs[jobID]?.state == .running {
                alert.addAction(UIAlertAction(title: "Cancel Build", style: .destructive) { _ in Task {
                    do {
                        _ = try await self.rpc("cancel", ["id": jobID])
                        let job = try await self.fetchJob(jobID); self.jobs[jobID] = job
                        self.monitor?.observe(job); self.tableView.reloadData()
                    } catch { self.show(error.localizedDescription) }
                } })
            }
            let enabled = app["enabled"] as? Bool == true
            alert.addAction(UIAlertAction(title: enabled ? "Pause Refreshes" : "Refresh Every Six Days", style: .default) { _ in Task { do { _ = try await self.rpc("schedule", ["id": id, "enabled": !enabled, "intervalHours": 144]); self.refresh() } catch { self.show(error.localizedDescription) } } })
            if let jobID = (app["jobID"] ?? app["lastJobID"]) as? String { alert.addAction(UIAlertAction(title: "View Build Log", style: .default) { _ in Task { do { let job = try await self.fetchJob(jobID); if let monitor = self.monitor { monitor.show(job, from: self) } else { self.show(job.log) } } catch { self.show(error.localizedDescription) } } }) }
            if let jobID = (app["lastJobID"] ?? app["jobID"]) as? String {
                alert.addAction(UIAlertAction(title: "Cache for Mac-Free Refresh", style: .default) { _ in Task {
                    do {
                        try await CodeRefreshEngine.shared.cacheFromMac { offset in
                            let result = try await self.rpc("artifact", ["jobID": jobID, "offset": offset])
                            return try JSONDecoder().decode(CodeRefreshArchiveChunk.self, from: JSONSerialization.data(withJSONObject: result))
                        }
                        self.show("Build cached. Open Refresh to renew it on this phone.")
                    } catch { self.show(error.localizedDescription) }
                } })
            }
            alert.addAction(UIAlertAction(title: "Remove App Target", style: .destructive) { _ in Task { do { _ = try await self.rpc("target_remove", ["id": id]); self.refresh() } catch { self.show(error.localizedDescription) } } })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.popoverPresentationController?.sourceView = tableView; alert.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath); present(alert, animated: true)
        }
    }
    private func detectProjects() {
        let list = OrbitDetectedProjectsController(rpc: rpc) { [weak self] project, scheme in
            self?.add(project: project, scheme: scheme)
        }
        navigationController?.pushViewController(list, animated: true)
    }
    private func add(repository: String? = nil, project: String? = nil, scheme: String? = nil) {
        Task { do {
            let devices = try await rpc("devices", [:]) as? [[String: Any]] ?? []
            guard !devices.isEmpty else { show("Connect your phone to Xcode on the Mac first."); return }
            let picker = UIAlertController(title: "Choose a Phone", message: nil, preferredStyle: .actionSheet)
            for device in devices {
                picker.addAction(UIAlertAction(title: device["name"] as? String, style: .default) { _ in
                    let alert = UIAlertController(title: "Add App", message: "Only add source you trust. Xcode builds can run scripts on your Mac.", preferredStyle: .alert)
                    for placeholder in ["Xcode project path", "App scheme", "Branch", "Team ID (optional)"] { alert.addTextField { $0.placeholder = placeholder; $0.autocapitalizationType = .none; $0.autocorrectionType = .no } }
                    alert.textFields?[0].text = project; alert.textFields?[1].text = scheme; alert.textFields?[2].text = "main"
                    if scheme != nil { alert.textFields?[0].isEnabled = false; alert.textFields?[1].isEnabled = false }
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    alert.addAction(UIAlertAction(title: "Add App", style: .default) { _ in Task {
                        do {
                            let fields = alert.textFields ?? []
                            var params: [String: Any] = ["project": fields[0].text ?? "", "scheme": fields[1].text ?? "", "branch": fields[2].text ?? "main", "deviceID": device["id"] ?? "", "enabled": true, "intervalHours": 144, "trust": true]
                            if let team = fields[3].text, !team.isEmpty { params["teamID"] = team }
                            if let repository { params["repository"] = repository }
                            _ = try await self.rpc(repository == nil ? "target_add" : "repo_add", params)
                            self.search.searchBar.text = ""; self.search.isActive = false; self.refresh()
                        } catch { self.show(error.localizedDescription) }
                    } })
                    self.present(alert, animated: true)
                })
            }
            picker.addAction(UIAlertAction(title: "Cancel", style: .cancel)); picker.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem; present(picker, animated: true)
        } catch { show(error.localizedDescription) } }
    }
    private func show(_ text: String) { OrbitDiagnostics.shared.record("ui", "error_shown", ["error": text]); let alert = UIAlertController(title: "Orbit", message: text, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true) }
}


/// Lists the paired Mac's projects, never the phone's local filesystem.
@MainActor final class OrbitDetectedProjectsController: UITableViewController {
    private let rpc: (String, [String: Any]) async throws -> Any
    private let selected: (String, String) -> Void
    private var projects: [String] = []
    private var schemes: [String] = []
    private var project: String?
    private var loading = false
    init(rpc: @escaping (String, [String: Any]) async throws -> Any, selected: @escaping (String, String) -> Void) {
        self.rpc = rpc; self.selected = selected
        super.init(style: .insetGrouped); title = "Projects on Your Mac"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(scan), for: .valueChanged)
        scan()
    }
    @objc private func scan() {
        guard !loading else { return }
        project = nil; schemes = []; projects = []; loading = true
        title = "Projects on Your Mac"; tableView.reloadData()
        tableView.backgroundView = message("Looking for projects on your Mac…")
        Task {
            defer { loading = false; refreshControl?.endRefreshing() }
            do {
                projects = try await rpc("projects_detect", [:]) as? [String] ?? []
                tableView.backgroundView = projects.isEmpty ? message("No projects found. Choose a project in Orbit on your Mac, or pull to scan again.") : nil
                tableView.reloadData()
            } catch { tableView.backgroundView = message(error.localizedDescription) }
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { project == nil ? projects.count : schemes.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if project == nil {
            let path = projects[indexPath.row]
            cell.textLabel?.text = URL(fileURLWithPath: path).lastPathComponent
            cell.detailTextLabel?.text = path; cell.detailTextLabel?.numberOfLines = 2
        } else { cell.textLabel?.text = schemes[indexPath.row] }
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !loading else { return }
        if let project {
            let scheme = schemes[indexPath.row]
            navigationController?.popViewController(animated: false)
            selected(project, scheme)
            return
        }
        let path = projects[indexPath.row]
        let alert = UIAlertController(title: "Read App Schemes?", message: "Only open source you trust. Xcode can run project code on your Mac.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Read Schemes", style: .default) { _ in
            self.loading = true; self.title = "Reading App Schemes…"
            self.tableView.backgroundView = self.message("Reading app schemes…")
            Task {
                defer { self.loading = false }
                do {
                    let rows = try await self.rpc("project_apps", ["project": path, "trust": true]) as? [[String: Any]] ?? []
                    self.schemes = rows.compactMap { ($0["project"] as? [String: Any])?["scheme"] as? String }
                    self.project = path; self.title = "Choose an iOS App"
                    self.tableView.backgroundView = self.schemes.isEmpty ? self.message("No runnable iOS app schemes found. Pull to scan again.") : nil
                    self.tableView.reloadData()
                } catch {
                    self.title = "Projects on Your Mac"; self.tableView.backgroundView = nil
                    let errorAlert = UIAlertController(title: "Couldn’t Read Schemes", message: error.localizedDescription, preferredStyle: .alert)
                    errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(errorAlert, animated: true)
                }
            }
        })
        present(alert, animated: true)
    }
    private func message(_ text: String) -> UILabel {
        let label = UILabel(); label.text = text; label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .secondaryLabel
        return label
    }
}

/// Keep progress in the layout as the row grows for stages and Dynamic Type.
@MainActor private final class OrbitTargetCell: UITableViewCell {
    let icon = UIImageView()
    let name = UILabel()
    let detail = UILabel()
    let progress = UIProgressView(progressViewStyle: .default)
    let play = UIButton(type: .system)
    init() {
        super.init(style: .default, reuseIdentifier: nil)
        name.font = .preferredFont(forTextStyle: .body); name.numberOfLines = 2
        detail.font = .preferredFont(forTextStyle: .subheadline); detail.textColor = .secondaryLabel; detail.numberOfLines = 0
        name.adjustsFontForContentSizeCategory = true; detail.adjustsFontForContentSizeCategory = true
        icon.contentMode = .scaleAspectFit; icon.tintColor = .secondaryLabel
        icon.layer.cornerRadius = 10; icon.clipsToBounds = true
        progress.isAccessibilityElement = true; progress.accessibilityLabel = "Build progress"; progress.isHidden = true
        let body = UIStackView(arrangedSubviews: [name, detail, progress]); body.axis = .vertical; body.spacing = 6
        play.setImage(UIImage(systemName: "play.fill"), for: .normal)
        play.configuration = .tinted()
        play.widthAnchor.constraint(equalToConstant: 44).isActive = true
        play.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let row = UIStackView(arrangedSubviews: [icon, body, play]); row.spacing = 14; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 44), icon.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
}
