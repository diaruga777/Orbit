import UIKit

/// Optional setup stays outside onboarding. The banner never changes a route or
/// starts Apple sign-in; its buttons take the user to the existing native flows.
@MainActor final class OrbitSetupBannerController: OrbitTabBarController {
    private let banner = UIStackView()
    private var reservedBannerHeight: CGFloat = -1
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let title = UILabel(); title.text = "Take Orbit with you"; title.font = .preferredFont(forTextStyle: .headline)
        let detail = UILabel(); detail.text = "Refresh without your Mac, or build away from home."; detail.font = .preferredFont(forTextStyle: .subheadline); detail.textColor = .secondaryLabel; detail.numberOfLines = 0
        for label in [title, detail] { label.adjustsFontForContentSizeCategory = true }
        let close = UIButton(type: .system); close.setImage(UIImage(systemName: "xmark"), for: .normal); close.accessibilityLabel = "Dismiss setup banner"
        close.addAction(UIAction { [weak self] _ in self?.banner.isHidden = true; self?.view.setNeedsLayout(); UserDefaults.standard.set(true, forKey: "Orbit.dismissedExtraSetup") }, for: .touchUpInside)
        let heading = UIStackView(arrangedSubviews: [title, close]); heading.spacing = 12
        close.setContentHuggingPriority(.required, for: .horizontal)
        let refresh = UIButton(type: .system); refresh.setTitle("Phone-only refresh", for: .normal)
        refresh.addAction(UIAction { [weak self] _ in self?.openRefreshSetup() }, for: .touchUpInside)
        let remote = UIButton(type: .system); remote.setTitle("Remote builds", for: .normal)
        remote.addAction(UIAction { [weak self] _ in self?.showRemoteSetup() }, for: .touchUpInside)
        for button in [close, refresh, remote] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        close.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        refresh.configuration = .filled()
        remote.configuration = .tinted()
        let actions = UIStackView(arrangedSubviews: [refresh, remote]); actions.axis = .vertical; actions.spacing = 8; actions.distribution = .fillEqually
        banner.insetsLayoutMarginsFromSafeArea = false
        banner.axis = .vertical; banner.spacing = 10; banner.isLayoutMarginsRelativeArrangement = true
        banner.directionalLayoutMargins = .init(top: 12, leading: 20, bottom: 12, trailing: 20)
        banner.backgroundColor = .secondarySystemBackground
        [heading, detail, actions].forEach(banner.addArrangedSubview)
        banner.isHidden = UserDefaults.standard.bool(forKey: "Orbit.dismissedExtraSetup")
        view.addSubview(banner)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = banner.isHidden ? 0 : banner.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let systemTop = view.window?.safeAreaInsets.top ?? 0
        if abs(reservedBannerHeight - height) > 0.5 {
            reservedBannerHeight = height
            additionalSafeAreaInsets.top = height
        }
        let frame = CGRect(x: 0, y: systemTop, width: view.bounds.width, height: height)
        if banner.frame != frame { banner.frame = frame }
        if view.subviews.last !== banner { view.bringSubviewToFront(banner) }
    }

    func openRefreshSetup() {
        guard let navigation = destinations.first(where: { $0.tabBarItem.tag == 4 }) as? UINavigationController else { return }
        navigation.popToRootViewController(animated: false)
        destinationIndex = destinations.firstIndex(of: navigation) ?? 0
        if let controller = navigation.topViewController as? UITableViewController {
            controller.loadViewIfNeeded()
            controller.tableView.setContentOffset(.zero, animated: false)
        }
    }
    private func showRemoteSetup() {
        let alert = UIAlertController(title: "Build away from home", message: "In Orbit Mac, open Phone & Remote Setup and enable remote connections. Reopen Orbit Mac, create a new connection code, and paste it in this phone’s Mac tab.\n\nKeep your Mac awake with Orbit running. Authorize this phone by cable first so Apple installations can work remotely too.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Mac Tab", style: .default) { [weak self] _ in self?.destinationIndex = self?.destinations.firstIndex { $0.tabBarItem.tag == 3 } ?? 0 })
        alert.addAction(UIAlertAction(title: "Later", style: .cancel)); present(alert, animated: true)
    }
}
