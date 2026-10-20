#if os(iOS)
import UIKit
import OrbitCore

@MainActor final class CodeProjectSettingsController: UITableViewController {
    private let fields = (0..<4).map { _ in UITextField() }
    private let labels = ["Project Path", "Scheme", "App ID", "Internal Group ID"]
    private let onSave: (CodeProject) -> Void

    init(project: CodeProject?, onSave: @escaping (CodeProject) -> Void) {
        self.onSave = onSave
        super.init(style: .insetGrouped)
        for (field, value) in zip(fields, [project?.path, project?.scheme, project?.appID, project?.groupID]) {
            field.text = value; field.autocorrectionType = .no; field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
            field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
        }
        for (field, label) in zip(fields, labels) { field.accessibilityIdentifier = "CodeSettings:" + label; field.accessibilityLabel = label }
        fields[0].placeholder = "/path/App.xcodeproj"
        fields[1].placeholder = "Choose on Save"
        fields[2].placeholder = "Optional"; fields[3].placeholder = "Optional"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad(); title = "Project Settings"
        tableView.keyboardDismissMode = .interactive
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.save() })
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Project" : "TestFlight" }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let index = indexPath.section * 2 + indexPath.row
        let cell = UITableViewCell(); cell.selectionStyle = .none
        let label = UILabel(); label.text = labels[index]; label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel; label.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [label, fields[index]])
        stack.axis = .vertical; stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12)
        ])
        return cell
    }
    private func save() {
        let values = fields.map { ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values[0].hasPrefix("/"), ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: values[0]).pathExtension) else {
            let alert = UIAlertController(title: "Invalid Project Path", message: "Choose an .xcodeproj or .xcworkspace file on your Mac.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true); return
        }
        let project = CodeProject(path: values[0], scheme: values[1], appID: values[2], groupID: values[3])
        dismiss(animated: true) { self.onSave(project) }
    }
}
#endif
