import UIKit
import UniformTypeIdentifiers
import WidgetKit
import OrbitWidgets

/// Shares import through the same Keychain group as Orbit and WidgetKit; no App Group is needed.
@MainActor final class OrbitShareController: UIViewController {
    private let status = UILabel()
    private let add = UIButton(type: .system)
    private let actions = UIStackView()
    private var file: OrbitJavaScriptFile?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 320)
        let title = UILabel(); title.text = "Import to Orbit"; title.font = .preferredFont(forTextStyle: .title2)
        title.numberOfLines = 0; title.adjustsFontForContentSizeCategory = true
        status.font = .preferredFont(forTextStyle: .body); status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0; status.text = "Reading JavaScript…"
        add.setTitle("Add", for: .normal); add.isEnabled = false
        add.addAction(UIAction { [weak self] _ in self?.install() }, for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle("Cancel", for: .normal)
        cancel.addAction(UIAction { [weak self] _ in self?.extensionContext?.completeRequest(returningItems: nil) }, for: .touchUpInside)
        let scroll = UIScrollView()
        let stack = UIStackView(arrangedSubviews: [title, status])
        stack.axis = .vertical; stack.spacing = 12
        actions.addArrangedSubview(cancel); actions.addArrangedSubview(add)
        actions.axis = .horizontal; actions.distribution = .fillEqually; actions.spacing = 12
        add.configuration = .filled()
        cancel.configuration = .bordered()
        view.addSubview(scroll); scroll.addSubview(stack); view.addSubview(actions)
        for child in [scroll, stack, actions] { child.translatesAutoresizingMaskIntoConstraints = false }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            actions.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            actions.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        loadFile()
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let narrow = view.safeAreaLayoutGuide.layoutFrame.width < 600
        actions.axis = narrow && traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
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
            var websites = file.script.definition.domains.isEmpty ? "No network access." : "Websites: " + file.script.definition.domains.joined(separator: ", ")
            if file.kind == .applet, let consent = try OrbitAppletDefinition.parse(file.script.source).pollingConsent { websites += "\n\n" + consent }
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
