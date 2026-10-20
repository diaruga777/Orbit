#if os(iOS)
import UIKit

/// All content participates in Auto Layout, including the switch and progress.
@MainActor final class CodeBuildAppCell: UITableViewCell {
    let nameLabel = UILabel()
    let detailLabel = UILabel()
    let icon = UIImageView()
    let play = UIButton(type: .system)
    let more = UIButton(type: .system)
    let nightly = UISwitch()
    let progress = UIProgressView(progressViewStyle: .default)
    private let footer = UIStackView()
    private var iconData: Data?

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        nameLabel.font = .preferredFont(forTextStyle: .headline)
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        for label in [nameLabel, detailLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 10
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.tintColor = .secondaryLabel
        icon.isAccessibilityElement = true
        icon.accessibilityLabel = "App icon"
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44)
        ])
        let heading = UIStackView(arrangedSubviews: [icon, nameLabel])
        heading.spacing = 12; heading.alignment = .center
        let overnight = UILabel()
        overnight.text = "Overnight"
        overnight.font = .preferredFont(forTextStyle: .subheadline)
        overnight.adjustsFontForContentSizeCategory = true
        overnight.numberOfLines = 0
        nightly.setContentHuggingPriority(.required, for: .horizontal)
        nightly.setContentCompressionResistancePriority(.required, for: .horizontal)
        let schedule = UIStackView(arrangedSubviews: [overnight, nightly])
        schedule.spacing = 8; schedule.alignment = .center
        let actions = UIStackView(arrangedSubviews: [play, more])
        actions.spacing = 8; actions.alignment = .center
        for button in [play, more] {
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44)
            ])
        }
        footer.addArrangedSubview(schedule)
        footer.addArrangedSubview(UIView())
        footer.addArrangedSubview(actions)
        footer.spacing = 12
        footer.alignment = .center
        progress.isAccessibilityElement = true
        progress.accessibilityLabel = "Build progress"
        progress.isHidden = true
        let body = UIStackView(arrangedSubviews: [heading, detailLabel, footer, progress])
        body.axis = .vertical; body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(body)
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: margins.topAnchor),
            body.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: margins.bottomAnchor)
        ])
        updateFooter()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: CodeBuildAppCell, _: UITraitCollection) in
            cell.updateFooter()
        }
        setIcon(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setIcon(_ data: Data?) {
        guard icon.image == nil || iconData != data else { return }
        iconData = data
        icon.image = data.flatMap { UIImage(data: $0) } ?? UIImage(systemName: "app.dashed")
    }
    private func updateFooter() {
        footer.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
        footer.alignment = footer.axis == .vertical ? .leading : .center
        footer.arrangedSubviews[1].isHidden = footer.axis == .vertical
    }
}
#endif
