import UIKit
import OrbitCore
import OrbitRefresh

@MainActor final class OrbitTargetsController: UITableViewController, UISearchResultsUpdating {
    private let rpc: (String, [String: Any]) async throws -> Any
    private var apps: [[String: Any]] = []
    private var repositories: [[String: Any]] = []
    private var searchTask: Task<Void, Never>?
    private let search = UISearchController(searchResultsController: nil)
    convenience init(connection: OrbitPhoneConnection) {
        self.init(rpc: { method, params in try await connection.rpc(method, params) })
    }
    init(rpc: @escaping (String, [String: Any]) async throws -> Any) {
        self.rpc = rpc; super.init(style: .insetGrouped); title = "Apps"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); tableView.cellLayoutMarginsFollowReadableWidth = true; search.searchResultsUpdater = self; search.searchBar.placeholder = "Search GitHub"
        navigationItem.searchController = search
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.add() })
        refreshControl = UIRefreshControl(); refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); refresh() }
    @objc private func refresh() { Task { defer { refreshControl?.endRefreshing() }; do { apps = try await rpc("targets", [:]) as? [[String: Any]] ?? []; tableView.reloadData() } catch { show(error.localizedDescription) } } }
    func updateSearchResults(for searchController: UISearchController) {
        searchTask?.cancel()
        let query = searchController.searchBar.text ?? ""
        guard !query.isEmpty else { repositories = []; tableView.reloadData(); return }
        searchTask = Task { do { try await Task.sleep(for: .milliseconds(400)); let rows = try await rpc("repo_search", ["query": query]) as? [[String: Any]] ?? []; guard !Task.isCancelled else { return }; repositories = rows; tableView.reloadData() } catch is CancellationError { } catch { show(error.localizedDescription) } }
    }
    private var searching: Bool { !(search.searchBar.text ?? "").isEmpty }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { searching ? repositories.count : apps.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let row = searching ? repositories[indexPath.row] : apps[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = row[searching ? "repository" : "name"] as? String
        content.secondaryText = searching ? row["description"] as? String : (row["failure"] as? String ?? ((row["enabled"] as? Bool == true) ? "Refreshes every \(row["intervalHours"] ?? 144) hours" : "Manual builds"))
        content.textProperties.numberOfLines = 2; content.secondaryTextProperties.numberOfLines = 2
        if !searching {
            content.image = (row["iconPNG"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) } ?? UIImage(systemName: "app.dashed")
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            content.imageProperties.cornerRadius = 10
            content.imageProperties.tintColor = .secondaryLabel
        }
        cell.contentConfiguration = content
        if !searching { cell.accessibilityIdentifier = "OrbitTarget:" + (row["id"] as? String ?? "") }
        cell.accessoryType = .disclosureIndicator; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
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
            alert.addAction(UIAlertAction(title: "Build and Install", style: .default) { _ in Task { do { let job = try await self.rpc("build", ["id": id]) as? [String: Any] ?? [:]; self.show("Build started. Job: \(job["id"] ?? "")"); self.refresh() } catch { self.show(error.localizedDescription) } } })
            let enabled = app["enabled"] as? Bool == true
            alert.addAction(UIAlertAction(title: enabled ? "Pause Refreshes" : "Refresh Every Six Days", style: .default) { _ in Task { do { _ = try await self.rpc("schedule", ["id": id, "enabled": !enabled, "intervalHours": 144]); self.refresh() } catch { self.show(error.localizedDescription) } } })
            if let jobID = (app["jobID"] ?? app["lastJobID"]) as? String { alert.addAction(UIAlertAction(title: "View Build Log", style: .default) { _ in Task { do { let job = try await self.rpc("job", ["id": jobID]) as? [String: Any] ?? [:]; self.show((job["state"] as? String ?? "") + "\n" + (job["log"] as? String ?? "")) } catch { self.show(error.localizedDescription) } } }) }
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
    private func add(repository: String? = nil, project: String? = nil) {
        Task { do {
            let devices = try await rpc("devices", [:]) as? [[String: Any]] ?? []
            guard !devices.isEmpty else { show("Connect your phone to Xcode on the Mac first."); return }
            let picker = UIAlertController(title: "Choose a Phone", message: nil, preferredStyle: .actionSheet)
            for device in devices {
                picker.addAction(UIAlertAction(title: device["name"] as? String, style: .default) { _ in
                    let alert = UIAlertController(title: "Add App", message: "Only add source you trust. Xcode builds can run scripts on your Mac.", preferredStyle: .alert)
                    for placeholder in ["Xcode project path", "App scheme", "Branch", "Team ID (optional)"] { alert.addTextField { $0.placeholder = placeholder; $0.autocapitalizationType = .none; $0.autocorrectionType = .no } }
                    alert.textFields?[0].text = project; alert.textFields?[2].text = "main"
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
    private func show(_ text: String) { let alert = UIAlertController(title: "Orbit", message: text, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true) }
}
