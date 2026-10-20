#if os(iOS)
import UIKit
import OrbitCore

@MainActor public final class CodeTabsController: UITabBarController, UITabBarControllerDelegate {
    private let environment: CodeEnvironment
    public init(environment: CodeEnvironment) { self.environment = environment; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        let workspace = CodeWorkspaceController(environment: environment)
        workspace.tabBarItem = UITabBarItem(title: "Project", image: UIImage(systemName: "curlybraces"), tag: 0)
        let builds = UINavigationController(rootViewController: CodeBuildsController(environment: environment))
        builds.tabBarItem = UITabBarItem(title: "Builds", image: UIImage(systemName: "play.rectangle"), tag: 1)
        viewControllers = [workspace, builds]
        selectedIndex = CodeBuildCatalog(defaults: environment.defaults).selectedTab
        delegate = self
    }
    public func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        CodeBuildCatalog(defaults: environment.defaults).selectedTab = selectedIndex
    }
}

@MainActor final class CodeBuildsController: UITableViewController {
    private let environment: CodeEnvironment
    private var catalog: CodeBuildCatalog { CodeBuildCatalog(defaults: environment.defaults) }
    private var apps: [CodeBuildApp] { catalog.apps(peer: environment.peerID()) }
    private var dataSource: CodeBuildDataSource!
    private var displayedApps: [String: CodeBuildApp] = [:]
    private var scannedProjects: Set<String> = []
    private var devices: [CodeDevice] = []
    private var jobs: [String: CodeJob] = [:]
    private var discovery: Task<Void, Never>?
    private var poll: Timer?
    private var polling = false
    private var loading = false
    private var starting: String?
    private var peer = ""
    private var message: String?

    init(environment: CodeEnvironment) { self.environment = environment; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { discovery?.cancel(); poll?.invalidate() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Builds"
        NotificationCenter.default.addObserver(self, selector: #selector(buildChanged), name: CodeBuildMonitor.changed, object: environment.builds)
        dataSource = CodeBuildDataSource(tableView: tableView) { [weak self] _, _, key in
            guard let self, let app = self.displayedApps[key] else { return nil }
            return self.makeCell(app)
        }
        tableView.accessibilityIdentifier = "CodeBuilds"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 180
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }; self.navigationController?.pushViewController(self.environment.pairing(), animated: true)
        })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Mac Connection"
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(activate), name: UIApplication.didBecomeActiveNotification, object: nil)
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, (self.viewIfLoaded?.window != nil || self.presentedViewController?.viewIfLoaded?.window != nil), UIApplication.shared.applicationState == .active else { return }
                await self.refreshJobs()
            }
        }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); activate() }
    @objc private func activate() {
        if peer != environment.peerID() {
            discovery?.cancel(); loading = false; peer = environment.peerID(); devices = []; scannedProjects = []; jobs = [:]; starting = nil; message = nil
        }
        CodeNightlyScheduler.shared.schedule(peer: environment.peerID())
        reload()
        if !loading { load(refreshAll: false) }
        Task { await refreshJobs() }
    }
    @objc private func buildChanged() {
        if let job = environment.builds.job { jobs[job.id] = job; catalog.record(job, peer: environment.peerID()) }
        reload()
    }
    @objc private func refresh() { load(refreshAll: true) }
    private func load(refreshAll: Bool) {
        guard !loading else { return }
        loading = true; message = nil
        let peer = environment.peerID()
        let projects = environment.session.recentProjects(peer: peer)
        let paths = projects.filter { refreshAll || !scannedProjects.contains($0.path) }
        reload()
        discovery = Task { [weak self] in
            guard let self else { return }
            defer { if peer == environment.peerID() { loading = false; refreshControl?.endRefreshing(); reload() } }
            do {
                let response = try await environment.client.call(CodeRequest(.devices))
                guard peer == environment.peerID(), !Task.isCancelled else { return }
                guard let phones = response.devices else { throw CodeFailure("Update Orbit Mac to use phone builds.") }
                devices = phones
                if catalog.defaultDevice(peer: peer) == nil,
                   let phone = CodeBuildCatalog.resolveDevice(phones, preferred: nil, currentName: UIDevice.current.name) {
                    catalog.setDefaultDevice(phone.id, peer: peer)
                }
            } catch { if peer == environment.peerID() { message = error.localizedDescription } }
            for project in paths {
                guard peer == environment.peerID(), !Task.isCancelled else { return }
                do {
                    let schemes = try await environment.client.call(CodeRequest(.schemes, path: project.path)).schemes
                    var found: [CodeBuildApp] = []
                    var failures: [String] = []
                    for scheme in schemes {
                        guard peer == environment.peerID(), !Task.isCancelled else { return }
                        var request = CodeRequest(.apps, path: project.path)
                        request.project = CodeProject(path: project.path, scheme: scheme)
                        do {
                            let response = try await environment.client.call(request)
                            guard peer == environment.peerID(), !Task.isCancelled else { return }
                            guard let discovered = response.apps else { throw CodeFailure("Update Orbit Mac to use phone builds.") }
                            for app in discovered where !found.contains(where: { $0.key == app.key }) { found.append(app) }
                        } catch {
                            guard peer == environment.peerID(), !Task.isCancelled else { return }
                            failures.append(scheme + ": " + error.localizedDescription)
                            // Keep this scheme's cached row while still discovering later apps.
                            found += catalog.apps(peer: peer).filter { $0.project.path == project.path && $0.project.scheme == scheme }
                        }
                        // Publish each result immediately; retain unchecked cached schemes.
                        var partial = catalog.apps(peer: peer).filter { $0.project.path == project.path && $0.project.scheme != scheme }
                        for app in found where !partial.contains(where: { $0.key == app.key }) { partial.append(app) }
                        catalog.merge(partial, path: project.path, peer: peer); reload()
                    }
                    catalog.merge(found, path: project.path, peer: peer)
                    scannedProjects.insert(project.path)
                    if !failures.isEmpty { message = failures.joined(separator: "\n") }
                    else if found.isEmpty { message = "No runnable iOS apps found in " + (project.path as NSString).lastPathComponent + "." }
                } catch { if peer == environment.peerID() { message = error.localizedDescription } }
            }
        }
    }
    private func reload() {
        guard isViewLoaded else { return }
        let rows = apps
        displayedApps = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        let keys = rows.map(\.key)
        dataSource.footer = footerText
        if dataSource.snapshot().itemIdentifiers != keys || dataSource.snapshot().sectionIdentifiers.isEmpty {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0]); snapshot.appendItems(keys)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        // Keep the cell and its menu button alive during discovery and job polls.
        var resizeRows = false
        for cell in tableView.visibleCells {
            if let index = tableView.indexPath(for: cell), let key = dataSource.itemIdentifier(for: index), let app = displayedApps[key] {
                let row = cell as? CodeBuildAppCell
                let previousDetail = row?.detailLabel.text
                let wasProgressHidden = row?.progress.isHidden
                update(cell, app: app)
                resizeRows = resizeRows || previousDetail != row?.detailLabel.text || wasProgressHidden != row?.progress.isHidden
            }
        }
        if let footer = tableView.footerView(forSection: 0), footer.textLabel?.text != footerText {
            footer.textLabel?.text = footerText
            resizeRows = true
        }
        if resizeRows { tableView.beginUpdates(); tableView.endUpdates() }
        if rows.isEmpty {
            var config = loading ? UIContentUnavailableConfiguration.loading() : .empty()
            config.image = loading ? nil : UIImage(systemName: "iphone.and.arrow.forward")
            config.text = loading ? "Finding Apps…" : "No Apps"
            config.secondaryText = message ?? "Open a project to see its apps here."
            if !loading {
                config.button.title = message == nil ? "Open Project" : "Retry"
                config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    guard let self else { return }
                    if self.message != nil { self.refresh() } else { self.tabBarController?.selectedIndex = 0; self.catalog.selectedTab = 0 }
                }
            }
            tableView.backgroundView = UIContentUnavailableView(configuration: config)
        } else { tableView.backgroundView = nil }
    }
    private var footerText: String {
        if let message { return message }
        if starting != nil { return environment.builds.backgroundMessage }
        if loading { return "Finding Apps…" }
        return apps.contains { $0.nightlyEnabled == true }
            ? "Overnight builds use your Mac’s local Wi-Fi. iOS chooses when to run them. Installation may need you to unlock your phone."
            : ""
    }
    private func phone(for app: CodeBuildApp) -> CodeDevice? {
        CodeBuildCatalog.resolveDevice(devices, preferred: app.deviceID ?? catalog.defaultDevice(peer: environment.peerID()), currentName: UIDevice.current.name)
    }
    private func makeCell(_ app: CodeBuildApp) -> UITableViewCell {
        let cell = CodeBuildAppCell()
        cell.accessibilityIdentifier = "CodeBuildApp:" + app.project.scheme
        let play = cell.play
        play.accessibilityLabel = "Build and Run " + app.name
        play.accessibilityIdentifier = "CodeRun:" + app.project.scheme
        play.addAction(UIAction { [weak self] _ in
            guard let self, let current = self.displayedApps[app.key] else { return }
            self.build(current)
        }, for: .touchUpInside)
        let more = cell.more
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        more.accessibilityLabel = "Build Options for " + app.name
        more.accessibilityIdentifier = "CodeBuildOptions:" + app.project.scheme
        more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, let current = self.displayedApps[app.key] else { completion([]); return }
            completion(self.menu(current).children)
        }])
        more.showsMenuAsPrimaryAction = true
        cell.progress.accessibilityIdentifier = "CodeRowProgress:" + app.project.scheme
        let nightly = cell.nightly
        nightly.accessibilityLabel = "Overnight builds for " + app.project.scheme
        nightly.accessibilityIdentifier = "CodeNightly:" + app.project.scheme
        nightly.addAction(UIAction { [weak self, weak nightly] _ in
            guard let self, let nightly, let current = self.displayedApps[app.key] else { return }
            self.edit(current) { $0.nightlyEnabled = nightly.isOn }
            CodeNightlyScheduler.shared.schedule(peer: self.environment.peerID())
        }, for: .valueChanged)
        update(cell, app: app)
        return cell
    }
    private func update(_ cell: UITableViewCell, app: CodeBuildApp) {
        guard let cell = cell as? CodeBuildAppCell else { return }
        let job = app.jobID.flatMap { jobs[$0] }
        let busy = starting == app.key || job?.state == .running
        let fraction = starting == app.key ? environment.builds.fraction : (job.map { environment.builds.fraction(for: $0) } ?? 0)
        cell.nameLabel.text = app.name
        cell.detailLabel.text = rowDetail(app)
        cell.setIcon(app.iconPNG)
        cell.icon.accessibilityIdentifier = "CodeAppIcon:" + app.project.scheme
        cell.nightly.isOn = app.nightlyEnabled == true
        cell.progress.isHidden = !busy
        cell.progress.progress = Float(fraction)
        cell.progress.accessibilityValue = "\(Int(fraction * 100)) percent estimated"
        let play = cell.play
        if play.configuration == nil {
            var config = UIButton.Configuration.tinted(); config.image = UIImage(systemName: "play.fill"); config.cornerStyle = .capsule
            config.showsActivityIndicator = false
            play.configuration = config
        }
        play.isEnabled = starting == nil && !jobs.values.contains { $0.state == .running }
    }
    private func rowDetail(_ app: CodeBuildApp) -> String {
        let job = app.jobID.flatMap { jobs[$0] }
        let fraction = starting == app.key ? environment.builds.fraction : (job.map { environment.builds.fraction(for: $0) } ?? 0)
        let status = starting == app.key ? "Starting… · Keep Orbit open" : job.map {
            $0.state == .running ? "\(Int(fraction * 100))% estimated · " + $0.progressStage + ($0.progressDetail.map { "\n" + $0 } ?? "") : $0.state.rawValue.capitalized
        }
        let history = app.lastBuiltAt.map { "Built " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not built yet"
        let revision = app.commitHash.map { String($0.prefix(8)) }
        return [app.name == app.project.scheme ? nil : app.project.scheme, history, revision, status, app.nightlyFailure].compactMap { $0 }.joined(separator: "\n")
    }
    private func menu(_ app: CodeBuildApp) -> UIMenu {
        let defaults = UIAction(title: "Default Phone", state: app.deviceID == nil ? .on : .off) { [weak self] _ in self?.edit(app) { $0.deviceID = nil } }
        let phones = devices.map { device in
            UIAction(title: device.name, image: UIImage(systemName: "iphone"), state: app.deviceID == device.id ? .on : .off) { [weak self] _ in self?.edit(app) { $0.deviceID = device.id } }
        }
        var actions: [UIMenuElement] = [
            UIMenu(title: "Target Device", children: [defaults] + phones + [UIAction(title: "Refresh Connected Phones…") { [weak self] _ in self?.chooseDefaultPhone() }]),
            UIAction(title: "Branch: " + app.branch, image: UIImage(systemName: "arrow.triangle.branch")) { [weak self] _ in self?.chooseBranch(app) },
            UIAction(title: "Open in Project", image: UIImage(systemName: "curlybraces")) { [weak self] _ in
                guard let self else { return }
                var project = self.environment.session.recentProjects(peer: self.environment.peerID()).first { $0.path == app.project.path } ?? app.project
                project.scheme = app.project.scheme
                self.environment.project = project; self.tabBarController?.selectedIndex = 0; self.catalog.selectedTab = 0
            }
        ]
        if let id = app.jobID {
            actions.append(UIAction(title: "Build Log", image: UIImage(systemName: "terminal")) { [weak self] _ in self?.showLog(id) })
            if jobs[id]?.state == .running {
                actions.append(UIAction(title: "Cancel Build", image: UIImage(systemName: "stop"), attributes: .destructive) { [weak self] _ in self?.cancel(id) })
            }
        }
        return UIMenu(children: actions)
    }
    private func edit(_ app: CodeBuildApp, update: (inout CodeBuildApp) -> Void) {
        var rows = apps
        guard let index = rows.firstIndex(where: { $0.key == app.key }) else { return }
        update(&rows[index]); catalog.save(rows, peer: environment.peerID()); reload()
    }
    private func build(_ app: CodeBuildApp) {
        guard starting == nil else { return }
        do { try environment.builds.begin(title: "Build & Run · " + app.project.scheme) }
        catch { showError(error); return }
        starting = app.key; reload()
        let peer = environment.peerID()
        Task {
            defer { environment.builds.endStarting(peer: peer); if peer == environment.peerID() { starting = nil; reload() } }
            do {
                guard let phones = try await environment.client.call(CodeRequest(.devices)).devices else { throw CodeFailure("Update Orbit Mac to use phone builds.") }
                guard peer == environment.peerID() else { return }
                devices = phones
                guard let target = phone(for: app) else {
                    if app.deviceID != nil || catalog.defaultDevice(peer: peer) != nil || phones.isEmpty {
                        throw CodeFailure("The selected phone is not connected. Connect it to your Mac by cable or on the same network, unlock it, and enable Developer Mode in Settings → Privacy & Security. Then try again.")
                    }
                    chooseDefaultPhone(for: app); return
                }
                if catalog.defaultDevice(peer: peer) == nil { catalog.setDefaultDevice(target.id, peer: peer) }
                var request = CodeRequest(.runOnDevice); request.project = app.project
                request.deviceBuild = CodeDeviceBuild(branch: app.branch, deviceID: target.id, monitorBundleID: Bundle.main.bundleIdentifier)
                let response = try await environment.client.call(request)
                guard peer == environment.peerID() else { return }
                guard let job = response.job else { throw CodeFailure("The Mac did not confirm the build. Update Orbit Mac and try again.") }
                environment.builds.accept(job)
                jobs[job.id] = job; edit(app) { $0.jobID = job.id }; showLog(job.id, showConsole: false)
            } catch { if peer == environment.peerID() { showError(error) } }
        }
    }
    private func chooseDefaultPhone(for app: CodeBuildApp? = nil) {
        choose(title: "Default Phone", load: { [environment] in
            guard let devices = try await environment.client.call(CodeRequest(.devices)).devices else { throw CodeFailure("Update Orbit Mac to use phone builds.") }
            return devices
        }, label: { $0.name }, select: { [weak self] device in
            guard let self else { return }
            self.catalog.setDefaultDevice(device.id, peer: self.environment.peerID())
            if let app { self.edit(app) { $0.deviceID = nil }; self.build(self.appWithDefaultDevice(app)) }
            else { self.load(refreshAll: false) }
        })
    }
    private func appWithDefaultDevice(_ app: CodeBuildApp) -> CodeBuildApp { var result = app; result.deviceID = nil; return result }
    private func chooseBranch(_ app: CodeBuildApp) {
        choose(title: "Branch", load: { [environment] in
            try await environment.client.call(CodeRequest(.branches, path: app.project.path)).branches ?? []
        }, label: { $0 }, select: { [weak self] branch in self?.edit(app) { $0.branch = branch } })
    }
    private func choose<T>(title: String, load: @escaping () async throws -> [T], label: @escaping (T) -> String, select: @escaping (T) -> Void) {
        let peer = environment.peerID()
        let list = CodeListController(title: title, rows: []) { _ in }
        present(UINavigationController(rootViewController: list), animated: true); list.showLoading("Loading " + title + "…")
        Task {
            do {
                let values = try await load()
                guard peer == environment.peerID(), list.presentingViewController != nil || list.navigationController?.presentingViewController != nil else { return }
                list.setRows(values.map(label), emptyMessage: "No choices available. Check the project or phone connection on the Mac, then try again.") { [weak list, weak self] index in
                    guard let self, peer == self.environment.peerID() else { return }
                    list?.dismiss(animated: true) { select(values[index]) }
                }
            } catch { if peer == environment.peerID() { list.showMessage(error.localizedDescription) } }
        }
    }
    private func refreshJobs() async {
        guard !polling else { return }; polling = true
        defer { polling = false }
        let peer = environment.peerID()
        var changed = false
        for id in Set(apps.compactMap(\.jobID)) where jobs[id] == nil || jobs[id]?.state == .running {
            var request = CodeRequest(.job); request.jobID = id
            if let job = try? await environment.client.call(request).job, peer == environment.peerID() {
                changed = changed || jobs[id]?.state != job.state
                jobs[id] = job
                catalog.record(job, peer: peer)
                environment.builds.observe(job)
                if let log = (presentedViewController as? UINavigationController)?.topViewController as? CodeLogController, log.jobID == job.id { log.update(job) }
            }
        }
        if changed, peer == environment.peerID() { reload() }
    }
    private func showLog(_ id: String, showConsole: Bool = true) {
        let peer = environment.peerID()
        Task {
            do {
                if jobs[id] == nil {
                    var request = CodeRequest(.job); request.jobID = id
                    let job = try await environment.client.call(request).job
                    guard peer == environment.peerID() else { return }; jobs[id] = job
                }
                guard peer == environment.peerID(), let job = jobs[id], presentedViewController == nil else { return }
                let log = CodeLogController(job: job, showConsole: showConsole, monitor: environment.builds)
                present(UINavigationController(rootViewController: log), animated: true)
            } catch { if peer == environment.peerID() { showError(error) } }
        }
    }
    private func cancel(_ id: String) {
        let peer = environment.peerID()
        Task {
            do {
                var request = CodeRequest(.cancel); request.jobID = id
                let job = try await environment.client.call(request).job
                guard peer == environment.peerID() else { return }; jobs[id] = job; reload()
            } catch { if peer == environment.peerID() { showError(error) } }
        }
    }
    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "Builds", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
private final class CodeBuildDataSource: UITableViewDiffableDataSource<Int, String> {
    var footer: String = ""
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { "Apps" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { footer }
}
#endif
