import UIKit

/// Optional setup stays outside onboarding. The banner never changes a route or
/// starts Apple sign-in; its buttons take the user to the existing native flows.
@MainActor final class OrbitSetupBannerController: UIViewController {
    let tabs: UITabBarController
    private let banner = UIStackView()
    init(tabs: UITabBarController) { self.tabs = tabs; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let title = UILabel(); title.text = "Take Orbit with you"; title.font = .preferredFont(forTextStyle: .headline)
        let detail = UILabel(); detail.text = "Refresh without your Mac, or build away from home."; detail.font = .preferredFont(forTextStyle: .subheadline); detail.textColor = .secondaryLabel; detail.numberOfLines = 0
        for label in [title, detail] { label.adjustsFontForContentSizeCategory = true }
        let close = UIButton(type: .system); close.setImage(UIImage(systemName: "xmark"), for: .normal); close.accessibilityLabel = "Dismiss setup banner"
        close.addAction(UIAction { [weak self] _ in self?.banner.isHidden = true; UserDefaults.standard.set(true, forKey: "Orbit.dismissedExtraSetup") }, for: .touchUpInside)
        let heading = UIStackView(arrangedSubviews: [title, close]); heading.spacing = 12
        close.setContentHuggingPriority(.required, for: .horizontal)
        let refresh = UIButton(type: .system); refresh.setTitle("Phone-only refresh", for: .normal)
        refresh.addAction(UIAction { [weak self] _ in self?.tabs.selectedIndex = 3 }, for: .touchUpInside)
        let remote = UIButton(type: .system); remote.setTitle("Remote builds", for: .normal)
        remote.addAction(UIAction { [weak self] _ in self?.showRemoteSetup() }, for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [refresh, remote]); actions.spacing = 20; actions.distribution = .fillEqually
        banner.axis = .vertical; banner.spacing = 6; banner.isLayoutMarginsRelativeArrangement = true
        banner.directionalLayoutMargins = .init(top: 12, leading: 20, bottom: 12, trailing: 20)
        banner.backgroundColor = .secondarySystemBackground
        [heading, detail, actions].forEach(banner.addArrangedSubview)
        banner.isHidden = UserDefaults.standard.bool(forKey: "Orbit.dismissedExtraSetup")
        addChild(tabs)
        let stack = UIStackView(arrangedSubviews: [banner, tabs.view]); stack.axis = .vertical; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        tabs.didMove(toParent: self)
    }
    private func showRemoteSetup() {
        let alert = UIAlertController(title: "Build away from home", message: "In Orbit Mac, open Phone & Remote Setup and enable remote connections. Reopen Orbit Mac, create a new connection code, and paste it in this phone’s Mac tab.\n\nKeep your Mac awake with Orbit running. Authorize this phone by cable first so Apple installations can work remotely too.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Mac Tab", style: .default) { [weak self] _ in self?.tabs.selectedIndex = 4 })
        alert.addAction(UIAlertAction(title: "Later", style: .cancel)); present(alert, animated: true)
    }
}
