import UIKit
import OrbitCore
import OrbitRefresh
import OrbitUI
import OrbitTransport

@MainActor final class OrbitTargetsController: UICollectionViewController, UISearchResultsUpdating {
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
    private let appsCache: OrbitPageCache
    private let macCache: OrbitPageCache
    private var loaded = false
    private var peer = ""
    private var apps: [[String: Any]] = []
    private var repositories: [[String: Any]] = []
    private var searchTask: Task<Void, Never>?
    private let search = UISearchController(searchResultsController: nil)
    convenience init(connection: OrbitPhoneConnection, monitor: CodeBuildMonitor) {
        self.init(rpc: { method, params in try await connection.rpc(method, params) }, monitor: monitor, peerID: { connection.peerID })
    }
    init(rpc: @escaping (String, [String: Any]) async throws -> Any, monitor: CodeBuildMonitor? = nil, peerID: @escaping () -> String = { "preview" }, refreshInterval: TimeInterval = 3, preparePhoneInstall: @escaping () async throws -> Void = { try await OrbitInstallNetwork.requireWiFi() }, defaults: UserDefaults = .standard) {
        appsCache = OrbitPageCache(key: "Orbit.appsSnapshot", defaults: defaults)
        macCache = OrbitPageCache(key: "Orbit.macSnapshot", defaults: defaults)
        self.preparePhoneInstall = preparePhoneInstall; self.refreshInterval = refreshInterval; self.monitor = monitor; self.peerID = peerID; self.rpc = rpc; super.init(collectionViewLayout: UICollectionViewFlowLayout()); title = "Apps"
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { poll?.invalidate(); searchTask?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad(); OrbitDiagnostics.shared.record("screen", "apps_loaded"); search.searchResultsUpdater = self; search.searchBar.placeholder = "Search GitHub"
        navigationItem.searchController = search
        collectionView.accessibilityIdentifier = "OrbitTargets"
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.register(OrbitTargetCell.self, forCellWithReuseIdentifier: "target")
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "list")
        collectionView.register(OrbitTargetsMessageCell.self, forCellWithReuseIdentifier: "message")
        collectionView.register(OrbitTargetsHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        if let monitor { NotificationCenter.default.addObserver(self, selector: #selector(buildChanged), name: CodeBuildMonitor.changed, object: monitor) }
        poll = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active else { return }
                await self.refreshTargets(showError: false)
            }
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.detectProjects() })
        collectionView.refreshControl = UIRefreshControl(); collectionView.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); restoreCachedState(); refresh() }
    @objc private func refresh() {
        OrbitDiagnostics.shared.record("action", "apps_refresh")
        Task { await refreshTargets(showError: true) }
    }
    private func restoreCachedState() {
        let origin = peerID()
        guard peer != origin else { return }
        peer = origin; jobs = [:]; apps = []; macUpdate = [:]
        startingMacUpdate = false; starting = nil; loaded = false; listMessage = "Loading apps…"
        if let data = appsCache.load(peer: origin),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           rows.allSatisfy({ $0["id"] is String && $0["name"] is String }) {
            apps = rows; loaded = true; listMessage = nil
        }
        if let data = macCache.load(peer: origin), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            macUpdate = value
        }
        collectionView.reloadData()
    }
    private func updateListMessage() {
        // Empty/error messaging belongs to Apps; keep the Mac section visible.
        collectionView.backgroundView = nil
    }

    private func refreshTargets(showError: Bool) async {
        restoreCachedState()
        guard !refreshing else { return }
        refreshing = true
        if !loaded { listMessage = "Loading apps…" }
        updateListMessage()
        defer { refreshing = false; collectionView.refreshControl?.endRefreshing(); updateListMessage(); collectionView.reloadData() }
        let origin = peerID()
        async let macStatus: Void = refreshMacStatus(origin: origin)
        do {
            guard let rows = try await rpc("targets", [:]) as? [[String: Any]], rows.allSatisfy({ $0["id"] is String && $0["name"] is String }) else { throw CodeFailure("Your Mac sent an invalid app list. Update Orbit Mac and retry.") }
            guard origin == peerID() else { return }
            appsCache.save(try JSONSerialization.data(withJSONObject: rows), peer: origin)
            apps = rows; loaded = true; listMessage = nil; collectionView.reloadData(); updateListMessage()
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
            collectionView.reloadData()
        } catch {
            guard origin == peerID() else { return }
            listMessage = error.localizedDescription
            OrbitDiagnostics.shared.error("apps", "load_failed", error)
            if showError, !apps.isEmpty, presentedViewController == nil { show(error.localizedDescription) }
        }
        await macStatus
    }
    private func refreshMacStatus(origin: String) async {
        do {
            guard let value = try await rpc("mac_update_status", [:]) as? [String: Any] else {
                throw CodeFailure("Your Mac sent an invalid update status. Update Orbit Mac and retry.")
            }
            if origin == peerID() {
                macUpdate = value
                if let data = try? JSONSerialization.data(withJSONObject: value) { macCache.save(data, peer: origin) }
                collectionView.reloadData()
            }
        } catch {
            if origin == peerID(), macBusy { macUpdate["stage"] = "Reconnecting to Orbit Mac…" }
        }
    }
    private func fetchJob(_ id: String) async throws -> CodeJob {
        try CodeJob.targetStatus(JSONSerialization.data(withJSONObject: await rpc("job", ["id": id])))
    }
    @objc private func buildChanged() {
        if let job = monitor?.job { jobs[job.id] = job }
        guard !searching else { return }
        for cell in collectionView.visibleCells {
            guard let index = collectionView.indexPath(for: cell), index.section == 1, apps.indices.contains(index.row) else { continue }
            configure(cell, row: apps[index.row])
        }
        collectionView.collectionViewLayout.invalidateLayout()
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
                if row["mac"] == nil { try await preparePhoneInstall() }
                guard origin == peerID(), UIApplication.shared.applicationState == .active else { return }
                try monitor.begin(title: (row["mac"] == nil ? "Build & Install · " : "Build on Mac · ") + (row["name"] as? String ?? "App"))
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
        guard !query.isEmpty else { repositories = []; collectionView.reloadData(); return }
        searchTask = Task { do { try await Task.sleep(for: .milliseconds(400)); let rows = try await rpc("repo_search", ["query": query]) as? [[String: Any]] ?? []; guard !Task.isCancelled else { return }; repositories = rows; collectionView.reloadData() } catch is CancellationError { } catch { show(error.localizedDescription) } }
    }
    private var searching: Bool { !(search.searchBar.text ?? "").isEmpty }
    private var macBusy: Bool { startingMacUpdate || ["accepted", "building", "installing", "restarting", "installed"].contains(macUpdate["state"] as? String ?? "") }
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let section: NSCollectionLayoutSection
            if !self.searching, sectionIndex == 1, !self.apps.isEmpty {
                let tileWidth = max(1, (environment.container.effectiveContentSize.width - 44) / 2)
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(tileWidth), heightDimension: .estimated(260)))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(260)),
                    repeatingSubitem: item, count: 2)
                group.interItemSpacing = .fixed(12)
                section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 12
                section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 24, trailing: 16)
            } else {
                var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                configuration.headerMode = .none
                section = .list(using: configuration, layoutEnvironment: environment)
            }
            if !self.searching {
                section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
            }
            return section
        }
    }
    override func numberOfSections(in collectionView: UICollectionView) -> Int { searching ? 1 : 2 }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { searching ? repositories.count : section == 0 ? 1 : max(1, apps.count) }
    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath) as! OrbitTargetsHeader
        header.label.text = indexPath.section == 0 ? "Orbit Mac" : "Apps"
        return header
    }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if !searching, indexPath.section == 1, !apps.isEmpty {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "target", for: indexPath) as! OrbitTargetCell
            configure(cell, row: apps[indexPath.item])
            return cell
        }
        if !searching, indexPath.section == 1 {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "message", for: indexPath) as! OrbitTargetsMessageCell
            cell.message.text = listMessage ?? "No apps yet. Tap + to add one from your Mac."
            cell.retry.isHidden = listMessage == nil
            cell.retry.removeAction(identifiedBy: UIAction.Identifier("retry"), for: .touchUpInside)
            cell.retry.addAction(UIAction(identifier: UIAction.Identifier("retry")) { [weak self] _ in self?.refresh() }, for: .touchUpInside)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "list", for: indexPath) as! UICollectionViewListCell
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.numberOfLines = 0
        content.textProperties.numberOfLines = 0
        cell.accessories = []; cell.accessibilityIdentifier = nil
        if !searching, indexPath.section == 0 {
            content.text = macBusy ? "Updating Orbit Mac…" : "Rebuild Orbit Mac"
            content.secondaryText = macUpdate["failure"] as? String ?? macUpdate["stage"] as? String ?? "Update Orbit Mac from Xcode once to enable this."
            content.image = UIImage(systemName: "desktopcomputer")
            let button = UIButton(type: .system)
            button.configuration = .tinted(); button.setImage(UIImage(systemName: "arrow.triangle.2.circlepath"), for: .normal)
            button.configuration?.showsActivityIndicator = macBusy
            button.isEnabled = !macBusy && macUpdate["available"] as? Bool == true
            button.accessibilityLabel = "Rebuild Orbit Mac"; button.accessibilityIdentifier = "OrbitMacRebuild"
            button.addAction(UIAction { [weak self] _ in self?.rebuildMac() }, for: .touchUpInside)
            cell.accessories = [.customView(configuration: .init(customView: button, placement: .trailing()))]
            cell.accessibilityIdentifier = "OrbitMacUpdate"
        } else {
            let row = repositories[indexPath.item]
            content.text = row["repository"] as? String; content.secondaryText = row["description"] as? String
            cell.accessories = [.disclosureIndicator()]
        }
        cell.contentConfiguration = content
        return cell
    }
    private func rebuildMac() {
        guard !macBusy else { return }
        let origin = peerID()
        startingMacUpdate = true; collectionView.reloadData()
        Task {
            defer { if origin == peerID() { startingMacUpdate = false; collectionView.reloadData() } }
            do {
                let result = try await rpc("mac_update", [:]) as? [String: Any] ?? [:]
                if origin == peerID() { macUpdate = result }
            } catch {
                if origin == peerID() { show("Couldn’t confirm the update request. Check Mac update progress before trying again.\n\n" + error.localizedDescription) }
            }
        }
    }
    private func configure(_ cell: UICollectionViewCell, row: [String: Any]) {
        let id = row["id"] as? String ?? ""
        let job = ((row["jobID"] ?? row["lastJobID"]) as? String).flatMap { jobs[$0] }
        let busy = starting == id || job?.state == .running
        guard let cell = cell as? OrbitTargetCell else { return }
        cell.name.text = row["name"] as? String
        cell.play.accessibilityIdentifier = "OrbitTargetPlay:" + id
        cell.play.accessibilityLabel = (row["mac"] == nil ? "Build and install " : "Build and open on Mac ") + (row["name"] as? String ?? "app")
        cell.play.isEnabled = monitor != nil && !busy && monitor?.isStarting != true && monitor?.job?.state != .running
        cell.play.removeAction(identifiedBy: UIAction.Identifier("play"), for: .touchUpInside)
        cell.play.addAction(UIAction(identifier: UIAction.Identifier("play")) { [weak self] _ in self?.build(row) }, for: .touchUpInside)
        let schedule = (row["enabled"] as? Bool == true) ? "Refreshes every \(row["intervalHours"] ?? 144) hours" : "Manual builds"
        let status: String?
        if starting == id { status = "Starting on your Mac…" }
        else if let job {
            status = job.state == .running
                ? job.progressStage + (job.progressDetail.map { "\n" + $0 } ?? "") + "\n" + (monitor?.backgroundMessage ?? "")
                : job.state == .succeeded ? (row["mac"] == nil ? "Installed on your phone" : "Installed on your Mac") : job.failureMessage ?? "Build " + job.state.rawValue
        } else { status = row["failure"] as? String }
        cell.accessibilityHint = schedule + ". Tap for app options."
        cell.detail.text = status
        cell.detail.isHidden = status?.isEmpty != false
        let built = (row["lastSuccess"] as? Double).flatMap { $0.isFinite && $0 >= Date.distantPast.timeIntervalSinceReferenceDate && $0 <= Date.distantFuture.timeIntervalSinceReferenceDate ? Date(timeIntervalSinceReferenceDate: $0) : nil }
        cell.setLastBuilt(built, id: id)
        cell.icon.image = (row["iconPNG"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) } ?? UIImage(systemName: "app.dashed")
        cell.accessibilityIdentifier = "OrbitTarget:" + id
        cell.progress.isHidden = !busy; cell.progress.update(job)
        cell.progress.accessibilityIdentifier = "OrbitTargetProgress:" + id
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
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
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.popoverPresentationController?.sourceView = collectionView; alert.popoverPresentationController?.sourceRect = collectionView.layoutAttributesForItem(at: indexPath)?.frame ?? collectionView.bounds; present(alert, animated: true)
            } catch { show(error.localizedDescription) } }
        } else {
            let app = apps[indexPath.row], id = app["id"] as? String ?? ""
            let alert = UIAlertController(title: app["name"] as? String, message: nil, preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: app["mac"] == nil ? "Build and Install" : "Build and Open on Mac", style: .default) { _ in self.build(app) })
            if let jobID = app["jobID"] as? String, jobs[jobID]?.state == .running {
                alert.addAction(UIAlertAction(title: "Cancel Build", style: .destructive) { _ in Task {
                    do {
                        _ = try await self.rpc("cancel", ["id": jobID])
                        let job = try await self.fetchJob(jobID); self.jobs[jobID] = job
                        self.monitor?.observe(job); self.collectionView.reloadData()
                    } catch { self.show(error.localizedDescription) }
                } })
            }
            let enabled = app["enabled"] as? Bool == true
            alert.addAction(UIAlertAction(title: enabled ? "Pause Refreshes" : "Refresh Every Six Days", style: .default) { _ in Task { do { _ = try await self.rpc("schedule", ["id": id, "enabled": !enabled, "intervalHours": 144]); self.refresh() } catch { self.show(error.localizedDescription) } } })
            if let jobID = (app["jobID"] ?? app["lastJobID"]) as? String { alert.addAction(UIAlertAction(title: "View Build Log", style: .default) { _ in Task { do { let job = try await self.fetchJob(jobID); if let monitor = self.monitor { monitor.show(job, from: self) } else { self.show(job.log) } } catch { self.show(error.localizedDescription) } } }) }
            if app["mac"] == nil, let jobID = (app["lastJobID"] ?? app["jobID"]) as? String {
                alert.addAction(UIAlertAction(title: "Cache for Mac-Free Refresh", style: .default) { _ in Task {
                    do {
                        try await CodeRefreshEngine.shared.cacheFromMac { offset in
                            let result = try await self.rpc("artifact", ["jobID": jobID, "offset": offset])
                            return try JSONDecoder().decode(CodeRefreshArchiveChunk.self, from: JSONSerialization.data(withJSONObject: result))
                        }
                        self.show("Build cached. Open More → Phone-only refresh to renew it on this phone.")
                    } catch { self.show(error.localizedDescription) }
                } })
            }
            alert.addAction(UIAlertAction(title: "Remove App Target", style: .destructive) { _ in Task { do { _ = try await self.rpc("target_remove", ["id": id]); self.refresh() } catch { self.show(error.localizedDescription) } } })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.popoverPresentationController?.sourceView = collectionView; alert.popoverPresentationController?.sourceRect = collectionView.layoutAttributesForItem(at: indexPath)?.frame ?? collectionView.bounds; present(alert, animated: true)
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

/// Two-column tiles keep the icon dominant and the last build beside Play.
@MainActor private final class OrbitTargetCell: UICollectionViewCell {
    let icon = UIImageView()
    let name = UILabel()
    let detail = UILabel()
    let progress = CodeBuildProgressView()
    let play = UIButton(type: .system)
    private let lastBuilt = UILabel()
    private let history = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 20; contentView.layer.cornerCurve = .continuous
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 12, bottom: 12, trailing: 12)
        name.font = .preferredFont(forTextStyle: .headline); name.numberOfLines = 2; name.textAlignment = .center
        detail.font = .preferredFont(forTextStyle: .caption1); detail.textColor = .secondaryLabel; detail.numberOfLines = 0
        for label in [name, detail, lastBuilt] { label.adjustsFontForContentSizeCategory = true }
        icon.contentMode = .scaleAspectFit; icon.tintColor = .tertiaryLabel
        icon.layer.cornerRadius = 24; icon.layer.cornerCurve = .continuous; icon.clipsToBounds = true
        icon.accessibilityIdentifier = "OrbitTargetIcon"
        let artwork = UIView(); artwork.addSubview(icon); icon.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = icon.widthAnchor.constraint(equalTo: artwork.widthAnchor)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth, icon.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            icon.widthAnchor.constraint(lessThanOrEqualTo: artwork.widthAnchor),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            icon.centerXAnchor.constraint(equalTo: artwork.centerXAnchor),
            icon.topAnchor.constraint(equalTo: artwork.topAnchor), icon.bottomAnchor.constraint(equalTo: artwork.bottomAnchor)
        ])
        lastBuilt.font = .preferredFont(forTextStyle: .caption1); lastBuilt.textColor = .secondaryLabel
        lastBuilt.adjustsFontSizeToFitWidth = true; lastBuilt.minimumScaleFactor = 0.5
        lastBuilt.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let clock = UIImageView(image: UIImage(systemName: "clock.arrow.circlepath"))
        clock.tintColor = .secondaryLabel; clock.contentMode = .scaleAspectFit
        clock.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        clock.isAccessibilityElement = false
        history.addArrangedSubview(clock); history.addArrangedSubview(lastBuilt)
        history.spacing = 4; history.alignment = .center; history.isAccessibilityElement = true
        clock.widthAnchor.constraint(equalToConstant: 16).isActive = true
        clock.heightAnchor.constraint(equalToConstant: 16).isActive = true
        progress.isAccessibilityElement = true; progress.accessibilityLabel = "Build progress"; progress.isHidden = true
        play.configuration = .tinted(); play.configuration?.cornerStyle = .capsule
        play.setImage(UIImage(systemName: "play.fill"), for: .normal)
        play.widthAnchor.constraint(equalToConstant: 44).isActive = true
        play.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let actions = UIStackView(arrangedSubviews: [history, UIView(), play]); actions.spacing = 4; actions.alignment = .center
        let body = UIStackView(arrangedSubviews: [artwork, name, actions, progress, detail])
        body.axis = .vertical; body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            body.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
        let preferredBottom = body.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        preferredBottom.priority = .defaultHigh; preferredBottom.isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func setLastBuilt(_ date: Date?, id: String) {
        history.accessibilityIdentifier = "OrbitTargetLastBuilt:" + id
        guard let date else {
            lastBuilt.text = "—"; history.accessibilityLabel = "Not built yet"; history.accessibilityValue = "—"
            return
        }
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { lastBuilt.text = "now" }
        else if seconds < 3600 { lastBuilt.text = "\(Int(seconds / 60))m" }
        else if seconds < 86400 { lastBuilt.text = "\(Int(seconds / 3600))hr" }
        else { lastBuilt.text = "\(Int(seconds / 86400))d" }
        history.accessibilityValue = lastBuilt.text
        history.accessibilityLabel = "Last built " + min(date, Date()).formatted(.relative(presentation: .named))
    }
}

@MainActor private final class OrbitTargetsHeader: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote); label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true; label.accessibilityTraits = .header
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
}

@MainActor private final class OrbitTargetsMessageCell: UICollectionViewListCell {
    let message = UILabel()
    let retry = UIButton(type: .system)
    override init(frame: CGRect) {
        super.init(frame: frame)
        message.font = .preferredFont(forTextStyle: .body); message.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 0; message.accessibilityIdentifier = "OrbitTargetsMessage"
        retry.setTitle("Retry", for: .normal)
        retry.setContentCompressionResistancePriority(.required, for: .horizontal)
        retry.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let body = UIStackView(arrangedSubviews: [message, retry]); body.spacing = 12; body.alignment = .center
        body.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            body.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 8),
            body.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
}
