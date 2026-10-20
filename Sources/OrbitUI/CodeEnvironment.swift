#if os(iOS)
import UIKit
import OrbitCore

public struct CodeBrowserItem: Sendable {
    public var path: String
    public var name: String
    public var directory: Bool
    public init(path: String, name: String, directory: Bool) { self.path = path; self.name = name; self.directory = directory }
    public var project: Bool { path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") }
}
public struct CodeBrowserPage: Sendable {
    public var items: [CodeBrowserItem]
    public var next: Int64?
    public init(items: [CodeBrowserItem], next: Int64?) { self.items = items; self.next = next }
}
@MainActor public final class CodeEnvironment {
    public let client: CodeClient
    public let drafts: CodeDraftStore
    public let browse: (String?, Int64, Bool) async throws -> CodeBrowserPage
    public let pairing: () -> UIViewController
    public let peerID: () -> String
    public let defaults: UserDefaults
    public lazy var builds = CodeBuildMonitor(client: client, defaults: defaults, peerID: peerID)
    public var session: CodeSessionStore { CodeSessionStore(defaults: defaults) }
    var projectChanged: (() -> Void)?
    public var project: CodeProject? {
        get { session.project(peer: peerID()) }
        set { session.setProject(newValue, peer: peerID()); projectChanged?() }
    }
    public init(client: CodeClient, drafts: CodeDraftStore, defaults: UserDefaults = .standard,
                browse: @escaping (String?, Int64, Bool) async throws -> CodeBrowserPage,
                pairing: @escaping () -> UIViewController, peerID: @escaping () -> String) {
        self.client = client; self.drafts = drafts; self.defaults = defaults
        self.browse = browse; self.pairing = pairing; self.peerID = peerID
    }
}

@MainActor public final class CodeWorkspaceController: UISplitViewController, UISplitViewControllerDelegate {
    private let environment: CodeEnvironment
    private var editor: CodeEditorController!
    private var browserNavigation: UINavigationController!
    private var currentPeer = ""
    private var currentProject: String?
    public init(environment: CodeEnvironment) {
        self.environment = environment
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        primaryBackgroundStyle = .sidebar
        minimumPrimaryColumnWidth = 250; maximumPrimaryColumnWidth = 380
        preferredPrimaryColumnWidthFraction = 0.28
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        editor = CodeEditorController(environment: environment)
        browserNavigation = UINavigationController()
        setViewController(browserNavigation, for: .primary)
        setViewController(UINavigationController(rootViewController: editor), for: .secondary)
        editor.openFiles = { [weak self] in self?.show(.primary) }
        environment.projectChanged = { [weak self] in self?.restoreWorkspace() }
        NotificationCenter.default.addObserver(self, selector: #selector(checkPeer), name: UIApplication.didBecomeActiveNotification, object: nil)
        restoreWorkspace(force: true)
    }
    public func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        environment.session.lastFile(peer: environment.peerID()) == nil ? .primary : proposedTopColumn
    }
    @objc private func checkPeer() {
        if currentPeer != environment.peerID() { restoreWorkspace(force: true) }
    }
    private func restoreWorkspace(force: Bool = false) {
        let peer = environment.peerID(), project = environment.project
        guard force || currentPeer != peer || currentProject != project?.path else { editor.projectDidChange(); return }
        currentPeer = peer; currentProject = project?.path
        editor.resetWorkspace()
        browserNavigation.setViewControllers([makeBrowser(path: project?.root)], animated: false)
        editor.projectDidChange()
        if let path = environment.session.lastFile(peer: peer) {
            show(.secondary); editor.open(path: path)
        } else { show(.primary) }
    }
    private func makeBrowser(path: String?) -> CodeBrowserController {
        let browser = CodeBrowserController(environment: environment, path: path)
        browser.appeared = { [weak self] in self?.checkPeer() }
        browser.macFiles = { [weak self] in
            guard let self else { return }
            self.browserNavigation.setViewControllers([self.makeBrowser(path: nil)], animated: false)
        }
        browser.projectFiles = { [weak self] in
            guard let self, let project = self.environment.project else { return }
            self.browserNavigation.setViewControllers([self.makeBrowser(path: project.root)], animated: false)
        }
        browser.projectSettings = { [weak self, weak browser] in
            guard let browser else { return }; self?.editor.configureProject(from: browser)
        }
        browser.chooseScheme = { [weak self, weak browser] in
            guard let browser else { return }; self?.editor.chooseScheme(from: browser)
        }
        browser.open = { [weak self, weak browser] item in
            guard let self else { return }
            browser?.navigationItem.searchController?.isActive = false
            if item.project {
                if self.environment.project?.path == item.path {
                    self.browserNavigation.setViewControllers([self.makeBrowser(path: self.environment.project?.root)], animated: false)
                } else { self.environment.project = CodeProject(path: item.path) }
                // A project opens its source folder. Scheme setup is only needed for builds.
                self.show(.primary)
            } else if item.directory {
                self.browserNavigation.pushViewController(self.makeBrowser(path: item.path), animated: true)
            } else { self.show(.secondary); self.editor.open(path: item.path) }
        }
        return browser
    }
}

@MainActor final class CodeBrowserController: UITableViewController, UISearchResultsUpdating {
    let environment: CodeEnvironment
    let path: String?
    var open: ((CodeBrowserItem) -> Void)?
    var appeared: (() -> Void)?
    var macFiles: (() -> Void)?
    var projectFiles: (() -> Void)?
    var projectSettings: (() -> Void)?
    var chooseScheme: (() -> Void)?
    private var items: [CodeBrowserItem] = []
    private var nextOffset: Int64?
    private var loading = false
    private var hidden = false
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var loadError: String?
    private let search = UISearchController(searchResultsController: nil)
    init(environment: CodeEnvironment, path: String?) { self.environment = environment; self.path = path; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var filtered: [CodeBrowserItem] {
        let query = search.searchBar.text ?? ""
        return items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in a.directory != b.directory ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = path.map { ($0 as NSString).lastPathComponent } ?? "Mac Files"
        tableView.accessibilityIdentifier = "CodeFileBrowser"
        navigationItem.largeTitleDisplayMode = .never
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Find in this folder"
        navigationItem.searchController = search
        let settingsButton = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(settings))
        settingsButton.accessibilityLabel = "Mac Connection"
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: browserMenu())
        more.accessibilityLabel = "Browser Actions"
        navigationItem.rightBarButtonItems = [more, settingsButton]
        refreshControl = UIRefreshControl(); refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        tableView.keyboardDismissMode = .onDrag
        load(reset: true)
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); appeared?()
        navigationItem.rightBarButtonItems?.first?.menu = browserMenu()
        if !loading { load(reset: true) }
    }
    private func browserMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Project Files", image: UIImage(systemName: "folder"), attributes: environment.project == nil ? .disabled : []) { [weak self] _ in self?.projectFiles?() },
            UIAction(title: "Browse Mac Files", image: UIImage(systemName: "desktopcomputer")) { [weak self] _ in self?.macFiles?() },
            UIAction(title: "Choose Build Scheme…", image: UIImage(systemName: "hammer"), attributes: environment.project == nil ? .disabled : []) { [weak self] _ in self?.chooseScheme?() },
            UIAction(title: "Project Settings", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in self?.projectSettings?() },
            UIAction(title: "Show Hidden Files", image: UIImage(systemName: "eye"), state: hidden ? .on : .off) { [weak self] _ in
                guard let self else { return }; self.hidden.toggle()
                self.navigationItem.rightBarButtonItems?.first?.menu = self.browserMenu(); self.load(reset: true)
            },
            UIAction(title: "Go to Path…", image: UIImage(systemName: "folder")) { [weak self] _ in self?.goToPath() }
        ])
    }
    @objc private func refresh() { load(reset: true) }
    @objc private func settings() { navigationController?.pushViewController(environment.pairing(), animated: true) }
    private func goToPath() {
        let alert = UIAlertController(title: "Open Mac Path", message: "Enter a folder or source file path.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "/Users/you/Projects"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Folder", style: .default) { [weak self] _ in
            guard let path = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else { return }
            self?.open?(CodeBrowserItem(path: path, name: (path as NSString).lastPathComponent, directory: true))
        })
        alert.addAction(UIAlertAction(title: "Open File", style: .default) { [weak self] _ in
            guard let path = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else { return }
            self?.open?(CodeBrowserItem(path: path, name: (path as NSString).lastPathComponent, directory: false))
        })
        let openActions = Array(alert.actions.dropFirst())
        openActions.forEach { $0.isEnabled = false }
        alert.textFields?.first?.addAction(UIAction { [weak alert] _ in
            let valid = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") == true
            openActions.forEach { $0.isEnabled = valid }
        }, for: .editingChanged)
        present(alert, animated: true)
    }
    private func load(reset: Bool) {
        if loading && !reset { return }
        loadTask?.cancel(); loadGeneration += 1
        let generation = loadGeneration, peer = environment.peerID()
        loading = true; loadError = nil
        if reset { items = []; nextOffset = nil; tableView.reloadData() }
        updateBackground()
        loadTask = Task {
            defer { if generation == loadGeneration { loading = false; refreshControl?.endRefreshing(); updateBackground() } }
            do {
                let page = try await environment.browse(path, reset ? 0 : nextOffset ?? 0, hidden)
                guard !Task.isCancelled, generation == loadGeneration, peer == environment.peerID() else { return }
                items = reset ? page.items : items + page.items; nextOffset = page.next
                tableView.reloadData()
            } catch {
                guard !Task.isCancelled, generation == loadGeneration, peer == environment.peerID() else { return }
                loadError = error.localizedDescription
            }
        }
    }
    private func updateBackground() {
        if let loadError {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "wifi.exclamationmark")
            config.text = "Couldn’t Load Files"
            config.secondaryText = loadError
            config.button.title = "Retry"
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load(reset: true) }
            tableView.backgroundView = UIContentUnavailableView(configuration: config)
        } else if loading && items.isEmpty {
            var config = UIContentUnavailableConfiguration.loading(); config.text = "Loading Files…"
            tableView.backgroundView = UIContentUnavailableView(configuration: config)
        } else if filtered.isEmpty && nextOffset == nil {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "folder")
            config.text = items.isEmpty ? "Empty Folder" : "No Matching Files"
            config.secondaryText = items.isEmpty ? nil : "Try another name."
            tableView.backgroundView = UIContentUnavailableView(configuration: config)
        } else { tableView.backgroundView = nil }
    }
    func updateSearchResults(for searchController: UISearchController) { tableView.reloadData(); updateBackground() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count + (nextOffset == nil ? 0 : 1) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard indexPath.row < filtered.count else { cell.textLabel?.text = "Load More"; return cell }
        let item = filtered[indexPath.row]
        cell.textLabel?.text = item.name; cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.numberOfLines = 2; cell.textLabel?.lineBreakMode = .byTruncatingMiddle
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.imageView?.image = UIImage(systemName: item.project ? "hammer.fill" : item.directory ? "folder.fill" : "doc.text")
        cell.imageView?.tintColor = item.project ? .systemIndigo : .systemBlue
        cell.accessoryType = item.directory ? .disclosureIndicator : .none
        if item.project { cell.detailTextLabel?.text = item.path == environment.project?.path ? "Current Project" : nil }
        cell.accessibilityIdentifier = "CodeFile:" + item.path
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < filtered.count else { load(reset: false); return }
        open?(filtered[indexPath.row])
    }
}
#endif
