import UIKit
import UniformTypeIdentifiers
import WidgetKit
import OrbitWidgets

/// Shares import through the same Keychain group as Orbit and WidgetKit; no App Group is needed.
@MainActor final class OrbitShareController: UIViewController {
    private let status = UILabel()
    private let add = UIButton(type: .system)
    private var file: OrbitJavaScriptFile?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 320)
        let title = UILabel(); title.text = "Import to Orbit"; title.font = .preferredFont(forTextStyle: .title2)
        status.numberOfLines = 0; status.text = "Reading JavaScript…"
        add.setTitle("Add", for: .normal); add.isEnabled = false
        add.addAction(UIAction { [weak self] _ in self?.install() }, for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle("Cancel", for: .normal)
        cancel.addAction(UIAction { [weak self] _ in self?.extensionContext?.completeRequest(returningItems: nil) }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, status, add, cancel]); stack.axis = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)])
        loadFile()
    }
    private func loadFile() {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard attachments.count == 1, let provider = attachments.first else { status.text = "Share one Orbit .js file at a time."; return }
        if provider.hasItemConformingToTypeIdentifier(UTType.javaScript.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.javaScript.identifier) { [weak self] url, error in
                let result = Result { () throws -> OrbitJavaScriptFile in
                    guard let url else { throw error ?? OrbitWidgetError("Share an Orbit .js file.") }
                    // Item-provider temporary URLs need not preserve the .js suffix.
                    return try OrbitJavaScriptFile(url: url, requireJavaScriptExtension: false)
                }
                Task { @MainActor in self?.loaded(result) }
            }
        } else {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                let result = Result { () throws -> OrbitJavaScriptFile in
                    guard let url = item as? URL else { throw error ?? OrbitWidgetError("Share an Orbit .js file.") }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try OrbitJavaScriptFile(url: url)
                }
                Task { @MainActor in self?.loaded(result) }
            }
        }
    }
    private func loaded(_ result: Result<OrbitJavaScriptFile, Error>) {
        do {
            let file = try result.get(); self.file = file
            let websites = file.script.definition.domains.isEmpty ? "No network access." : "Websites: " + file.script.definition.domains.joined(separator: ", ")
            let store = OrbitWidgetStore(applets: file.kind == .applet)
            let replacing = try store.script(file.script.id) != nil
            status.text = file.script.definition.name + "\n\n" + websites + "\n\nThis JavaScript can save its own data on your phone. Only add code you trust."
            add.setTitle((replacing ? "Update " : "Add ") + (file.kind == .applet ? "Applet" : "Widget"), for: .normal); add.isEnabled = true
        } catch { status.text = error.localizedDescription }
    }
    private func install() {
        guard let file else { return }
        do {
            try OrbitWidgetStore(applets: file.kind == .applet).install(file.script.source)
            WidgetCenter.shared.reloadAllTimelines()
            status.text = "Added. Open Orbit to use it."; add.isEnabled = false
            extensionContext?.completeRequest(returningItems: nil)
        } catch { status.text = error.localizedDescription }
    }
}
