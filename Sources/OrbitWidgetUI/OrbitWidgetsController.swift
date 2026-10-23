#if os(iOS)
import UIKit
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit
import OrbitWidgets
import OrbitAppletUI

@MainActor public final class OrbitWidgetsController: UITableViewController, UIDocumentPickerDelegate {
    private let store: OrbitWidgetStore
    private let applets: Bool
    private var scripts: [OrbitWidgetScript] = []
    private let deployments: (() async throws -> [String])?
    public init(deployments: (() async throws -> [String])? = nil, applets: Bool = false) {
        self.deployments = deployments; self.applets = applets; store = OrbitWidgetStore(applets: applets); super.init(style: .insetGrouped); title = applets ? "Applets" : "Widgets"
    }
    required init?(coder: NSCoder) { fatalError() }
    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: nil, menu: UIMenu(children: [
            UIAction(title: "Import JavaScript", image: UIImage(systemName: "doc")) { [weak self] _ in self?.importFile() },
            UIAction(title: "Paste JavaScript", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste() },
            UIAction(title: "From Mac", image: UIImage(systemName: "desktopcomputer")) { [weak self] _ in self?.fromMac() },
            UIAction(title: "Copy AI Prompt", image: UIImage(systemName: "sparkles")) { [weak self] _ in UIPasteboard.general.string = self?.applets == true ? OrbitAppletPrompt.text : OrbitWidgetPrompt.text }
        ]))
        reload()
    }
    public override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }
    private func reload() { do { scripts = try store.scripts(); tableView.reloadData() } catch { show(error.localizedDescription) } }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, scripts.count) }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard !scripts.isEmpty else { cell.textLabel?.text = applets ? "Add Your First Applet" : "Add Your First Widget"; cell.detailTextLabel?.text = "Import a JavaScript file or copy a prompt to make one."; cell.detailTextLabel?.numberOfLines = 0; return cell }
        let script = scripts[indexPath.row]
        cell.textLabel?.text = script.definition.name
        cell.detailTextLabel?.text = applets ? "Tap to open" : "Requests updates every \(script.definition.refreshMinutes) minutes"
        cell.imageView?.image = UIImage(systemName: "square.grid.2x2"); cell.accessoryType = .disclosureIndicator; return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !scripts.isEmpty else { importFile(); return }
        launch(scripts[indexPath.row])
    }
    public override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard !scripts.isEmpty else { return }
        do { try store.remove(scripts[indexPath.row].id); WidgetCenter.shared.reloadAllTimelines(); reload() } catch { show(error.localizedDescription) }
    }
    private func importFile() { let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.javaScript, .plainText]); picker.delegate = self; present(picker, animated: true) }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if let url = urls.first { open(url) } }
    public func open(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= OrbitWidgetDefinition.maximumSourceBytes else { throw OrbitWidgetError("Choose a JavaScript file under 128 KB.") }
            review(try String(contentsOf: url, encoding: .utf8))
        } catch { show(error.localizedDescription) }
    }
    private func paste() {
        let controller = OrbitWidgetPasteController { [weak self] source in self?.review(source) }
        present(UINavigationController(rootViewController: controller), animated: true)
    }
    private func fromMac() {
        guard let deployments else { show(applets ? "Connect your Mac to receive applets." : "Connect your Mac to receive widgets."); return }
        Task { do {
            let sources = try await deployments()
            guard !sources.isEmpty else { show(applets ? "No applets waiting on your Mac." : "No widgets waiting on your Mac."); return }
            let picker = UIAlertController(title: "From Mac", message: nil, preferredStyle: .actionSheet)
            for source in sources {
                if let definition = try? definition(source) {
                    picker.addAction(UIAlertAction(title: definition.name, style: .default) { [weak self] _ in self?.review(source) })
                }
            }
            picker.addAction(UIAlertAction(title: "Cancel", style: .cancel)); picker.popoverPresentationController?.sourceView = view; present(picker, animated: true)
        } catch { show(error.localizedDescription) } }
    }
    public func review(_ source: String) {
        do {
            let definition = try definition(source)
            let replacing = try store.script(definition.id) != nil
            let websites = definition.domains.isEmpty ? "No network access." : "Websites: " + definition.domains.joined(separator: ", ")
            let alert = UIAlertController(title: (replacing ? "Update " : "Add ") + definition.name + "?", message: websites + "\n\nThis JavaScript can save its own data on your phone. Only add code you trust.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: applets ? (replacing ? "Update Applet" : "Add Applet") : (replacing ? "Update Widget" : "Add Widget"), style: .default) { [weak self] _ in
                guard let self else { return }; do {
                    try store.install(source); WidgetCenter.shared.reloadAllTimelines(); reload()
                    launch(try applets ? OrbitAppletDefinition.widgetScript(source) : OrbitWidgetScript(source: source))
                } catch { show(error.localizedDescription) }
            }); present(alert, animated: true)
        } catch { show(error.localizedDescription) }
    }
    private func definition(_ source: String) throws -> OrbitWidgetDefinition {
        try applets ? OrbitAppletDefinition.widgetScript(source).definition : OrbitWidgetDefinition.parse(source)
    }
    private func launch(_ script: OrbitWidgetScript) {
        if applets { navigationController?.pushViewController(UIHostingController(rootView: OrbitAppletView(script: script, store: store)), animated: true) }
        else { navigationController?.pushViewController(OrbitWidgetDetailController(script: script, store: store), animated: true) }
    }
    private func show(_ text: String) { let alert = UIAlertController(title: applets ? "Applets" : "Widgets", message: text, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true) }
}

@MainActor private final class OrbitWidgetPasteController: UIViewController {
    let editor = UITextView()
    let done: (String) -> Void
    init(done: @escaping (String) -> Void) { self.done = done; super.init(nibName: nil, bundle: nil); title = "JavaScript" }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = editor; editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular); editor.autocorrectionType = .no; editor.autocapitalizationType = .none; editor.backgroundColor = .systemBackground }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Review", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }; let source = editor.text ?? ""; dismiss(animated: true) { self.done(source) }
        })
    }
}

@MainActor private final class OrbitWidgetDetailController: UIViewController {
    let script: OrbitWidgetScript
    let store: OrbitWidgetStore
    let stack = UIStackView()
    let status = UILabel()
    let family = UISegmentedControl(items: ["Small", "Medium", "Large", "Lock Screen"])
    var preview: UIHostingController<AnyView>?
    var work: Task<Void, Never>?
    init(script: OrbitWidgetScript, store: OrbitWidgetStore) { self.script = script; self.store = store; super.init(nibName: nil, bundle: nil); title = script.definition.name }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)])
        family.selectedSegmentIndex = 1; family.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged); stack.addArrangedSubview(family)
        status.numberOfLines = 0; status.font = .preferredFont(forTextStyle: .footnote); status.textColor = .secondaryLabel; stack.addArrangedSubview(status)
        let help = UILabel(); help.numberOfLines = 0; help.font = .preferredFont(forTextStyle: .body)
        help.text = "Add an Orbit widget to your Home Screen or Lock Screen, then choose this widget in its settings. iOS decides when updates run."
        stack.addArrangedSubview(help)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.refresh() }); refresh()
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isMovingFromParent { work?.cancel() } }
    private func refresh() {
        work?.cancel(); let name = ["small", "medium", "large", "rectangular"][family.selectedSegmentIndex]
        status.text = "Updating…"
        work = Task {
            do {
                let output = try await OrbitWidgetRuntime.run(script: script, storage: store.storage(script.id), family: name)
                try Task.checkCancellation(); try store.save(output, script: script, family: name); WidgetCenter.shared.reloadAllTimelines()
                guard let entry = output.entries.first else { return }
                preview?.willMove(toParent: nil); preview?.view.removeFromSuperview(); preview?.removeFromParent()
                let host = UIHostingController(rootView: AnyView(OrbitWidgetView(node: entry.view).padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))))
                addChild(host); stack.insertArrangedSubview(host.view, at: 1); host.view.heightAnchor.constraint(equalToConstant: name == "large" ? 300 : 170).isActive = true; host.didMove(toParent: self); preview = host
                status.text = "Updated " + output.updatedAt.formatted(date: .omitted, time: .shortened)
            } catch is CancellationError { } catch { status.text = error.localizedDescription }
        }
    }
}
#endif
