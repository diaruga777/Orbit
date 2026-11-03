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
    private var requestFailures: [String: String] = [:]
    private weak var expandedTarget: OrbitTargetDetailController?
    private var cachingTarget: String?
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
        expandedTarget?.dismiss(animated: false); expandedTarget = nil
        peer = origin; jobs = [:]; requestFailures = [:]; apps = []; macUpdate = [:]
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
        defer { refreshing = false; collectionView.refreshControl?.endRefreshing(); updateListMessage(); collectionView.reloadData(); updateExpandedTarget() }
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
        updateExpandedTarget()
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
                requestFailures[id] = nil
                began = true; starting = id; buildChanged()
                let result = try await rpc("build", ["id": id, "monitorBundleID": Bundle.main.bundleIdentifier ?? ""])
                let job = try CodeJob.targetStatus(JSONSerialization.data(withJSONObject: result))
                OrbitDiagnostics.shared.record("build", "accepted", ["target": id, "job": job.id])
                guard origin == peerID() else { return }
                if let index = apps.firstIndex(where: { $0["id"] as? String == id }) { apps[index]["jobID"] = job.id }
                jobs[job.id] = job; monitor.accept(job)
                monitor.show(job, from: self.expandedTarget ?? self)
            } catch {
                if origin == peerID() {
                    if error is OrbitInstallNetwork.WiFiRequired {
                        let alert = UIAlertController(title: "Wi-Fi Needed", message: error.localizedDescription, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default)); (self.expandedTarget ?? self).present(alert, animated: true)
                    } else { requestFailures[id] = error.localizedDescription; buildChanged() }
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
                let width = environment.container.effectiveContentSize.width
                let tileWidth: CGFloat = 160
                let columns = max(1, Int((width - 20) / (tileWidth + 12)))
                let gridWidth = CGFloat(columns) * tileWidth + CGFloat(columns - 1) * 12
                let inset = max(16, (width - gridWidth) / 2)
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(tileWidth), heightDimension: .absolute(220)))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(220)),
                    repeatingSubitem: item, count: columns)
                group.interItemSpacing = .fixed(12)
                section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 12
                section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: inset, bottom: 24, trailing: inset)
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
        guard let cell = cell as? OrbitTargetCell else { return }
        configure(cell.card, row: row)
        cell.accessibilityIdentifier = "OrbitTarget:" + (row["id"] as? String ?? "")
        cell.accessibilityHint = "Tap for app options."
    }
    private func configure(_ cell: OrbitTargetCard, row: [String: Any]) {
        let id = row["id"] as? String ?? ""
        let job = ((row["jobID"] ?? row["lastJobID"]) as? String).flatMap { jobs[$0] }
        let busy = starting == id || job?.state == .running
        cell.name.text = row["name"] as? String
        cell.play.accessibilityIdentifier = "OrbitTargetPlay:" + id
        cell.play.accessibilityLabel = (row["mac"] == nil ? "Build and install " : "Build and open on Mac ") + (row["name"] as? String ?? "app")
        cell.play.isEnabled = monitor != nil && !busy && monitor?.isStarting != true && monitor?.job?.state != .running
        cell.play.removeAction(identifiedBy: UIAction.Identifier("play"), for: .touchUpInside)
        cell.play.addAction(UIAction(identifier: UIAction.Identifier("play")) { [weak self] _ in self?.build(row) }, for: .touchUpInside)
        let schedule = (row["enabled"] as? Bool == true) ? "Refreshes every \(row["intervalHours"] ?? 144) hours" : "Manual builds"
        let failure = requestFailures[id] ?? row["failure"] as? String
        let status: String?
        if starting == id { status = "Starting on your Mac…" }
        else if let failure, !failure.isEmpty, !busy { status = failure }
        else if let job {
            status = job.state == .running
                ? job.progressStage + (job.progressDetail.map { "\n" + $0 } ?? "") + "\n" + (monitor?.backgroundMessage ?? "")
                : job.state == .succeeded ? (row["mac"] == nil ? "Installed on your phone" : "Installed on your Mac") : job.failureMessage ?? "Build " + job.state.rawValue
        } else { status = nil }
        cell.accessibilityHint = schedule + ". Tap for app options."
        cell.accessibilityValue = busy ? status : nil
        cell.issue.isHidden = busy || !(job?.state == .failed || failure?.isEmpty == false)
        cell.issue.accessibilityIdentifier = "OrbitTargetIssue:" + id
        cell.issue.accessibilityLabel = "Build issue for " + (row["name"] as? String ?? "app")
        cell.issue.removeAction(identifiedBy: UIAction.Identifier("issue"), for: .touchUpInside)
        cell.issue.addAction(UIAction(identifier: UIAction.Identifier("issue")) { [weak self] _ in self?.openTarget(id) }, for: .touchUpInside)
        if expandedTarget?.targetID == id {
            let text = status.flatMap { $0.isEmpty ? nil : $0 } ?? "No build issues."
            if expandedTarget?.message.text != text { expandedTarget?.message.text = text }
            expandedTarget?.message.textColor = cell.issue.isHidden ? .secondaryLabel : .systemRed
            expandedTarget?.setSchedule(schedule)
            expandedTarget?.logs.isEnabled = (row["jobID"] ?? row["lastJobID"]) is String
            expandedTarget?.cache.isEnabled = cachingTarget != id && row["mac"] == nil && (row["lastJobID"] ?? row["jobID"]) is String
            expandedTarget?.cancel.isHidden = job?.state != .running
        }
        let built = (row["lastSuccess"] as? Double).flatMap { $0.isFinite && $0 >= Date.distantPast.timeIntervalSinceReferenceDate && $0 <= Date.distantFuture.timeIntervalSinceReferenceDate ? Date(timeIntervalSinceReferenceDate: $0) : nil }
        cell.setLastBuilt(built, id: id)
        cell.icon.image = (row["iconPNG"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) } ?? UIImage(systemName: "app.dashed")
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
            openTarget(apps[indexPath.row]["id"] as? String ?? "")
        }
    }
    private func openTarget(_ id: String) {
        guard expandedTarget == nil, let row = apps.first(where: { $0["id"] as? String == id }) else { return }
        let detail = OrbitTargetDetailController(targetID: id)
        detail.sourceFrame = { [weak self] in
            guard let self, let index = self.apps.firstIndex(where: { $0["id"] as? String == id }),
                  let cell = self.collectionView.cellForItem(at: IndexPath(item: index, section: 1)), let window = self.view.window else { return nil }
            return cell.convert(cell.bounds, to: window)
        }
        expandedTarget = detail
        detail.onDismiss = { [weak self, weak detail] in
            if self?.expandedTarget === detail { self?.expandedTarget = nil }
        }
        detail.loadViewIfNeeded()
        configure(detail.card, row: row)
        detail.onAction = { [weak self, weak detail] action in
            guard let self, let detail, let row = self.apps.first(where: { $0["id"] as? String == id }) else { return }
            switch action {
            case .schedule: self.configureSchedule(row, from: detail)
            case .remove:
                let alert = UIAlertController(title: "Remove this app?", message: "You can add it again from your Mac.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in Task {
                    do { _ = try await self.rpc("target_remove", ["id": id]); detail.dismiss(animated: true); self.refresh() }
                    catch { self.show(error.localizedDescription) }
                } })
                detail.present(alert, animated: true)
            case .logs:
                guard let jobID = (row["jobID"] ?? row["lastJobID"]) as? String else { return }
                Task { do {
                    let job = try await self.fetchJob(jobID)
                    if let monitor = self.monitor { monitor.show(job, from: detail, console: true) } else { self.show(job.log) }
                } catch { self.show(error.localizedDescription) } }
            case .cancel:
                guard let jobID = row["jobID"] as? String else { return }
                Task { do {
                    _ = try await self.rpc("cancel", ["id": jobID])
                    let job = try await self.fetchJob(jobID); self.jobs[jobID] = job
                    self.monitor?.observe(job); self.buildChanged(); self.refresh()
                } catch { self.show(error.localizedDescription) } }
            case .cache:
                guard let jobID = (row["lastJobID"] ?? row["jobID"]) as? String else { return }
                self.cachingTarget = id; detail.cache.isEnabled = false
                Task {
                    defer { self.cachingTarget = nil; self.updateExpandedTarget() }
                    do {
                        try await CodeRefreshEngine.shared.cacheFromMac { offset in
                            let result = try await self.rpc("artifact", ["jobID": jobID, "offset": offset])
                            return try JSONDecoder().decode(CodeRefreshArchiveChunk.self, from: JSONSerialization.data(withJSONObject: result))
                        }
                        self.show("Build cached. Open More → Phone-only refresh to renew it on this phone.")
                    } catch { self.show(error.localizedDescription) }
                }
            }
        }
        present(detail, animated: true)
    }
    private func updateExpandedTarget() {
        guard let detail = expandedTarget else { return }
        guard let row = apps.first(where: { $0["id"] as? String == detail.targetID }) else {
            detail.dismiss(animated: true); return
        }
        configure(detail.card, row: row)
    }
    private func configureSchedule(_ row: [String: Any], from detail: OrbitTargetDetailController) {
        guard let id = row["id"] as? String else { return }
        let alert = UIAlertController(title: "Refresh settings", message: "Your Mac builds and installs on this schedule.", preferredStyle: .actionSheet)
        let enabled = row["enabled"] as? Bool == true
        let options: [(String, Bool, Int)] = [("Manual builds", false, 144), ("Every day", true, 24), ("Every three days", true, 72), ("Every six days", true, 144)]
        for (title, active, hours) in options {
            let selected = active == enabled && (!active || row["intervalHours"] as? Int == hours)
            alert.addAction(UIAlertAction(title: title + (selected ? " ✓" : ""), style: .default) { _ in Task {
                do { _ = try await self.rpc("schedule", ["id": id, "enabled": active, "intervalHours": hours]); await self.refreshTargets(showError: true) }
                catch { self.show(error.localizedDescription) }
            } })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = detail.schedule
        alert.popoverPresentationController?.sourceRect = detail.schedule.bounds
        detail.present(alert, animated: true)
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
    private func show(_ text: String) { OrbitDiagnostics.shared.record("ui", "error_shown", ["error": text]); let alert = UIAlertController(title: "Orbit", message: text, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); (expandedTarget ?? self).present(alert, animated: true) }
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

/// Absolute grid geometry never depends on text, errors or build state.
@MainActor private final class OrbitTargetCell: UICollectionViewCell {
    let card = OrbitTargetCard()
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(card)
        card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.frame = contentView.bounds
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
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
