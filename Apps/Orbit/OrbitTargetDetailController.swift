import UIKit
import OrbitCore
import OrbitUI

/// Shared artwork and controls keep their size as the surrounding card expands.
@MainActor final class OrbitTargetCard: UIView {
    let icon = UIImageView()
    let name = UILabel()
    let progress = CodeBuildProgressView()
    let play = UIButton(type: .system)
    let issue = UIButton(type: .system)
    private let lastBuilt = UILabel()
    private let history = UIStackView()
    var compact = false { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 20; layer.cornerCurve = .continuous
        icon.contentMode = .scaleAspectFit; icon.tintColor = .tertiaryLabel
        icon.layer.cornerRadius = 14; icon.layer.cornerCurve = .continuous; icon.clipsToBounds = true
        icon.accessibilityIdentifier = "OrbitTargetIcon"
        name.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold), maximumPointSize: 22)
        name.numberOfLines = 2; name.textAlignment = .center
        name.adjustsFontForContentSizeCategory = true
        name.adjustsFontSizeToFitWidth = true; name.minimumScaleFactor = 0.75
        lastBuilt.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12), maximumPointSize: 20)
        lastBuilt.adjustsFontForContentSizeCategory = true
        lastBuilt.textColor = .secondaryLabel; lastBuilt.adjustsFontSizeToFitWidth = true; lastBuilt.minimumScaleFactor = 0.5
        let clock = UIImageView(image: UIImage(systemName: "clock.arrow.circlepath"))
        clock.tintColor = .secondaryLabel; clock.contentMode = .scaleAspectFit; clock.isAccessibilityElement = false
        clock.widthAnchor.constraint(equalToConstant: 16).isActive = true
        history.addArrangedSubview(clock); history.addArrangedSubview(lastBuilt)
        history.spacing = 4; history.alignment = .center; history.isAccessibilityElement = true
        play.configuration = .tinted(); play.configuration?.cornerStyle = .capsule
        play.setImage(UIImage(systemName: "play.fill"), for: .normal)
        issue.setImage(UIImage(systemName: "exclamationmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)), for: .normal)
        issue.tintColor = .systemRed; issue.isHidden = true
        progress.accessibilityLabel = "Build progress"; progress.isHidden = true
        for child in [icon, name, history, play, progress, issue] { addSubview(child) }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        if compact {
            icon.frame = CGRect(x: 16, y: 10, width: 60, height: 60)
            name.frame = CGRect(x: 88, y: 8, width: max(0, width - 304), height: 44)
            history.frame = CGRect(x: 88, y: 52, width: max(0, width - 304), height: 24)
            play.frame = CGRect(x: width - 112, y: 18, width: 44, height: 44)
            progress.frame = CGRect(x: width - 160, y: 30, width: 36, height: 20)
            issue.frame = CGRect(x: width - 208, y: 18, width: 44, height: 44)
        } else {
            icon.frame = CGRect(x: (width - 60) / 2, y: 16, width: 60, height: 60)
            name.frame = CGRect(x: 12, y: 84, width: max(0, width - 24), height: 46)
            history.frame = CGRect(x: 12, y: 142, width: max(0, width - 76), height: 44)
            play.frame = CGRect(x: width - 56, y: 142, width: 44, height: 44)
            progress.frame = CGRect(x: 12, y: 194, width: max(0, width - 24), height: 20)
            issue.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        }
    }
    func setLastBuilt(_ date: Date?, id: String) {
        history.accessibilityIdentifier = "OrbitTargetLastBuilt:" + id
        guard let date else {
            lastBuilt.text = "—"; history.accessibilityLabel = "Not built yet"; history.accessibilityValue = "—"; return
        }
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { lastBuilt.text = "now" }
        else if seconds < 3600 { lastBuilt.text = "\(Int(seconds / 60))m" }
        else if seconds < 86400 { lastBuilt.text = "\(Int(seconds / 3600))hr" }
        else { lastBuilt.text = "\(Int(seconds / 86400))d" }
        history.accessibilityValue = lastBuilt.text
        history.accessibilityLabel = "Last built " + min(date, Date()).formatted(.relative(presentation: .named))
    }
}

@MainActor final class OrbitTargetDetailController: UIViewController, UIViewControllerTransitioningDelegate {
    enum Action { case schedule, cache, logs, remove, cancel }
    let targetID: String
    let card = OrbitTargetCard()
    let message = UITextView()
    let schedule = UIButton(type: .system)
    let cache = UIButton(type: .system)
    let logs = UIButton(type: .system)
    let cancel = UIButton(type: .system)
    private let remove = UIButton(type: .system)
    private let close = UIButton(type: .system)
    private let settings = UIStackView()
    private let actions = UIStackView()
    var onAction: ((Action) -> Void)?
    var onDismiss: (() -> Void)?
    var sourceFrame: (() -> CGRect?)?
    var showingTileLayout = false

    init(targetID: String) {
        self.targetID = targetID
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom; transitioningDelegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 24; view.layer.cornerCurve = .continuous; view.clipsToBounds = true
        view.accessibilityIdentifier = "OrbitTargetDetail"
        view.accessibilityViewIsModal = true
        message.isEditable = false; message.isScrollEnabled = true; message.backgroundColor = .tertiarySystemGroupedBackground
        message.layer.cornerRadius = 12; message.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        message.font = .preferredFont(forTextStyle: .body); message.adjustsFontForContentSizeCategory = true
        message.accessibilityIdentifier = "OrbitTargetMessage"
        configure(schedule, title: "Refresh settings", symbol: "clock.arrow.circlepath", action: .schedule)
        configure(cache, title: "Cache build", symbol: "arrow.down.circle", action: .cache)
        configure(logs, title: "View Build Log", symbol: "doc.text.magnifyingglass", action: .logs, iconOnly: true)
        configure(remove, title: "Remove App Target", symbol: "trash", action: .remove, iconOnly: true)
        remove.tintColor = .systemRed
        configure(cancel, title: "Cancel Build", symbol: "stop.fill", action: .cancel, iconOnly: true)
        close.configuration = .plain(); close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .secondaryLabel; close.accessibilityLabel = "Close app details"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        settings.addArrangedSubview(schedule); settings.addArrangedSubview(cache)
        settings.distribution = .fillEqually; settings.spacing = 8
        for child in [remove, UIView(), cancel, logs] { actions.addArrangedSubview(child) }
        actions.spacing = 8
        for button in [remove, cancel, logs] { button.widthAnchor.constraint(equalToConstant: 44).isActive = true }
        for child in [card, message, settings, actions, close] { view.addSubview(child) }
    }
    private func configure(_ button: UIButton, title: String, symbol: String, action: Action, iconOnly: Bool = false) {
        var config = UIButton.Configuration.tinted()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
        config.imagePadding = 6; config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        if !iconOnly { config.title = title }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes; result.font = UIFont.systemFont(ofSize: 14, weight: .medium); return result
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes; result.font = UIFont.systemFont(ofSize: 12); return result
        }
        button.configuration = config; button.accessibilityLabel = title
        button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
    }
    func setSchedule(_ text: String) {
        schedule.accessibilityValue = text
        schedule.configuration?.subtitle = text.replacingOccurrences(of: "Refreshes every ", with: "Every ")
            .replacingOccurrences(of: " hours", with: "hr").replacingOccurrences(of: "Manual builds", with: "Manual")
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width, height = view.bounds.height
        let compact = !showingTileLayout && height < 440
        let header: CGFloat = compact ? 80 : 220
        card.compact = compact
        card.frame = CGRect(x: 0, y: 0, width: width, height: header)
        close.frame = CGRect(x: width - 48, y: 4, width: 44, height: 44)
        settings.frame = CGRect(x: 16, y: height - 112, width: max(0, width - 32), height: 52)
        actions.frame = CGRect(x: 16, y: height - 52, width: max(0, width - 32), height: 44)
        message.frame = CGRect(x: 16, y: header + 8, width: max(0, width - 32), height: max(0, height - header - 136))
    }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        OrbitTargetPresentationController(presentedViewController: presented, presenting: presenting)
    }
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        OrbitTargetExpansion(presenting: true, source: sourceFrame)
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        OrbitTargetExpansion(presenting: false, source: sourceFrame)
    }
}

@MainActor private final class OrbitTargetPresentationController: UIPresentationController {
    private let dim = UIView()
    private var previousAccessibilityHidden = false
    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        return containerView.bounds.inset(by: containerView.safeAreaInsets).insetBy(dx: 12, dy: 12)
    }
    override func presentationTransitionWillBegin() {
        guard let containerView else { return }
        previousAccessibilityHidden = presentingViewController.view.accessibilityElementsHidden
        presentingViewController.view.accessibilityElementsHidden = true
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.3); dim.frame = containerView.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]; dim.alpha = 0
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        containerView.insertSubview(dim, at: 0)
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in self.dim.alpha = 1 })
    }
    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed { presentingViewController.view.accessibilityElementsHidden = previousAccessibilityHidden }
    }
    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed {
            presentingViewController.view.accessibilityElementsHidden = previousAccessibilityHidden; dim.removeFromSuperview()
            (presentedViewController as? OrbitTargetDetailController)?.onDismiss?()
        }
    }
    override func dismissalTransitionWillBegin() {
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in self.dim.alpha = 0 })
    }
    override func containerViewWillLayoutSubviews() { presentedView?.frame = frameOfPresentedViewInContainerView }
    @objc private func close() { presentedViewController.dismiss(animated: true) }
}

@MainActor private final class OrbitTargetExpansion: NSObject, UIViewControllerAnimatedTransitioning {
    let presenting: Bool
    let source: (() -> CGRect?)?
    init(presenting: Bool, source: (() -> CGRect?)?) { self.presenting = presenting; self.source = source }
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval { UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.38 }
    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let controller = context.viewController(forKey: key), let card = controller.view else { context.completeTransition(false); return }
        let destination = context.finalFrame(for: controller)
        let sourceRect = source?()
        let origin = sourceRect.map { context.containerView.convert($0, from: context.containerView.window) }
        if presenting { context.containerView.addSubview(card) }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled || origin == nil
        let detail = controller as? OrbitTargetDetailController
        if presenting {
            detail?.showingTileLayout = !reduceMotion
            card.frame = reduceMotion ? destination : origin!
            card.alpha = reduceMotion ? 0 : 1
            card.layoutIfNeeded()
        }
        UIView.animate(withDuration: transitionDuration(using: context), delay: 0, options: [.curveEaseInOut]) {
            detail?.showingTileLayout = !self.presenting && !reduceMotion
            card.frame = self.presenting ? destination : (reduceMotion ? card.frame : origin!)
            card.alpha = self.presenting ? 1 : 0
            card.layoutIfNeeded()
        } completion: { _ in
            let completed = !context.transitionWasCancelled
            if !self.presenting && completed { card.removeFromSuperview() }
            context.completeTransition(completed)
        }
    }
}
