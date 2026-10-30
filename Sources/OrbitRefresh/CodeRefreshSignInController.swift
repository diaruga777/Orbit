#if os(iOS)
import UIKit
import SideSign
import OrbitCore

/// Owns the entire account flow, so errors and Apple challenges cannot be lost
/// behind a dismissing alert. Secrets exist here only for the life of the sheet.
@MainActor final class CodeRefreshSignInController: UIViewController, UITextFieldDelegate {
    private let service: any CodeRefreshSignInService
    private let signedIn: () -> Void
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let credentials = UIStackView()
    private let email = UITextField()
    private let password = UITextField()
    private let server = UITextField()
    private let remember = UISwitch()
    private let advanced = UIButton(type: .system)
    private let serverFields = UIStackView()
    private let feedback = UILabel()
    private let submit = UIButton(type: .system)
    private let challenge = UIStackView()
    private let code = UITextField()
    private let teams = UIStackView()
    private var work: Task<Void, Never>?
    private var verification: CheckedContinuation<TwoFactorResponse, Error>?

    init(service: any CodeRefreshSignInService, server: URL, signedIn: @escaping () -> Void) {
        self.service = service; self.signedIn = signedIn
        super.init(nibName: nil, bundle: nil)
        if server != CodeRefreshSignInInput.defaultServer { self.server.text = server.absoluteString }
        title = "Apple Account"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        for group in [credentials, serverFields, challenge, teams] { group.axis = .vertical; group.spacing = 16 }
        credentials.addArrangedSubview(label("Sign in to refresh apps without your Mac.", style: .body))
        configure(email, placeholder: "Apple Account email", content: .username)
        email.keyboardType = .emailAddress; email.returnKeyType = .next
        configure(password, placeholder: "Password", content: .password)
        password.isSecureTextEntry = true; password.returnKeyType = .go
        credentials.addArrangedSubview(field(email, title: "Email"))
        credentials.addArrangedSubview(field(password, title: "Password"))
        let rememberText = label("Remember password", style: .body)
        let row = UIStackView(arrangedSubviews: [rememberText, remember]); row.spacing = 16; row.alignment = .center
        remember.accessibilityLabel = "Remember password"
        credentials.addArrangedSubview(row)
        credentials.addArrangedSubview(label("Save it in this iPhone’s Keychain for automatic refresh. Leave this off to sign in again when your session expires.", style: .footnote))
        advanced.setTitle("Advanced", for: .normal)
        advanced.contentHorizontalAlignment = .leading
        advanced.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        advanced.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.serverFields.isHidden.toggle()
            self.advanced.accessibilityValue = self.serverFields.isHidden ? "Collapsed" : "Expanded"
        }, for: .touchUpInside)
        credentials.addArrangedSubview(advanced)
        configure(server, placeholder: "Automatic — SideStore", content: .URL)
        server.keyboardType = .URL; server.returnKeyType = .done
        serverFields.addArrangedSubview(field(server, title: "Anisette server (optional)"))
        serverFields.addArrangedSubview(label("Leave blank to use ani.sidestore.io, or enter your own HTTPS service.", style: .footnote))
        serverFields.isHidden = server.text?.isEmpty != false
        credentials.addArrangedSubview(serverFields)
        credentials.addArrangedSubview(label("Sign-in uses SideStore’s helper service. Your email and password go only to Apple.", style: .footnote))
        stack.addArrangedSubview(credentials)
        feedback.numberOfLines = 0; feedback.font = .preferredFont(forTextStyle: .body)
        feedback.adjustsFontForContentSizeCategory = true; feedback.isHidden = true
        feedback.accessibilityIdentifier = "refresh-sign-in-feedback"
        stack.addArrangedSubview(feedback)
        challenge.isHidden = true; teams.isHidden = true
        stack.addArrangedSubview(challenge); stack.addArrangedSubview(teams)
        submit.configuration = .filled(); submit.setTitle("Sign In", for: .normal)
        submit.titleLabel?.adjustsFontForContentSizeCategory = true
        submit.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        submit.addAction(UIAction { [weak self] _ in self?.signIn() }, for: .touchUpInside)
        stack.addArrangedSubview(submit)
    }

    private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let result = UILabel(); result.text = text; result.numberOfLines = 0
        result.font = .preferredFont(forTextStyle: style); result.adjustsFontForContentSizeCategory = true
        if style == .footnote { result.textColor = .secondaryLabel }
        return result
    }
    private func field(_ input: UITextField, title: String) -> UIStackView {
        let group = UIStackView(arrangedSubviews: [label(title, style: .subheadline), input])
        group.axis = .vertical; group.spacing = 8
        input.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return group
    }
    private func configure(_ input: UITextField, placeholder: String, content: UITextContentType) {
        input.placeholder = placeholder; input.accessibilityLabel = placeholder; input.textContentType = content
        input.borderStyle = .roundedRect; input.font = .preferredFont(forTextStyle: .body)
        input.adjustsFontForContentSizeCategory = true; input.autocapitalizationType = .none
        input.autocorrectionType = .no; input.delegate = self
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === email { password.becomeFirstResponder() }
        else if textField === password { signIn() }
        else { textField.resignFirstResponder() }
        return true
    }
    private func show(_ text: String, error: Bool = false) {
        feedback.text = text; feedback.textColor = error ? .systemRed : .secondaryLabel; feedback.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text)
        // Wait for the stack's new height before scrolling errors/progress into view.
        view.layoutIfNeeded(); scroll.scrollRectToVisible(feedback.convert(feedback.bounds, to: scroll), animated: true)
    }
    private func setBusy(_ busy: Bool) {
        isModalInPresentation = busy
        navigationController?.isModalInPresentation = busy
        for input in [email, password, server] { input.isEnabled = !busy }
        remember.isEnabled = !busy; advanced.isEnabled = !busy
        submit.isEnabled = !busy; submit.configuration?.showsActivityIndicator = busy
        submit.setTitle(busy ? "Signing in…" : "Sign In", for: .normal)
    }
    private func signIn() {
        guard work == nil else { return }
        let input: CodeRefreshSignInInput
        do {
            input = try CodeRefreshSignInInput(appleID: email.text ?? "", password: password.text ?? "",
                server: server.text ?? "", rememberPassword: remember.isOn)
        } catch { show(error.localizedDescription, error: true); return }
        view.endEditing(true); setBusy(true); show("Connecting to sign in…")
        work = Task {
            defer { work = nil; setBusy(false) }
            do {
                let available = try await service.signIn(appleID: input.appleID, password: input.password,
                    anisetteURL: input.server, rememberPassword: input.rememberPassword) { [weak self] request in
                        guard let self else { return .cancel }
                        return try await self.verify(request)
                    }
                try Task.checkCancellation()
                guard !available.isEmpty else { throw CodeFailure("No signing teams were found. Finish setting up this account in Xcode, then try again.") }
                password.text = nil
                if available.count == 1 {
                    do { try await service.select(available[0]); try Task.checkCancellation(); finish() }
                    catch { chooseTeam(available); throw error }
                } else { chooseTeam(available) }
            } catch is CancellationError { }
            catch {
                challenge.isHidden = true
                if teams.isHidden { credentials.isHidden = false; submit.isHidden = false }
                show(error.localizedDescription, error: true)
            }
        }
    }
    private func chooseTeam(_ available: [Team]) {
        credentials.isHidden = true; submit.isHidden = true; teams.isHidden = false
        show("Choose the team used for your apps.")
        for team in available {
            let button = UIButton(type: .system); button.configuration = .tinted()
            button.setTitle(team.type == .free ? team.name + " (Personal Team)" : team.name, for: .normal)
            button.titleLabel?.numberOfLines = 0
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
            button.addAction(UIAction { [weak self] _ in self?.select(team) }, for: .touchUpInside)
            teams.addArrangedSubview(button)
        }
    }
    private func select(_ team: Team) {
        guard work == nil else { return }
        setBusy(true); teams.isUserInteractionEnabled = false; show("Saving your team…")
        work = Task {
            defer { work = nil; setBusy(false); teams.isUserInteractionEnabled = true }
            do { try await service.select(team); try Task.checkCancellation(); finish() }
            catch is CancellationError { }
            catch { show(error.localizedDescription, error: true) }
        }
    }
    private func finish() {
        password.text = nil; signedIn(); dismiss(animated: true)
    }
    private func cancel() {
        work?.cancel(); reply(.cancel); password.text = nil; dismiss(animated: true)
    }
    private func reply(_ response: TwoFactorResponse) {
        let pending = verification; verification = nil
        challenge.isHidden = true; code.text = nil
        pending?.resume(returning: response)
    }
    private func verify(_ request: TwoFactorRequest) async throws -> TwoFactorResponse {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                verification = continuation
                credentials.isHidden = true; submit.isHidden = true
                challenge.arrangedSubviews.forEach { challenge.removeArrangedSubview($0); $0.removeFromSuperview() }
                challenge.isHidden = false
                show(request.error ?? "Verify your Apple Account.")
                switch request {
                case .selectDeliveryMethod(_, let phones):
                    addChallengeButton("Send to Apple Devices", response: .requestTrustedDevice)
                    for phone in phones { addChallengeButton("Text " + phone.number, response: .requestSMS(phoneID: phone.id)) }
                default:
                    configure(code, placeholder: "Verification code", content: .oneTimeCode); code.keyboardType = .numberPad
                    challenge.addArrangedSubview(field(code, title: "Enter the code from Apple"))
                    let next = UIButton(type: .system); next.configuration = .filled(); next.setTitle("Continue", for: .normal)
                    next.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
                    next.addAction(UIAction { [weak self] _ in
                        guard let self else { return }
                        let value = (self.code.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { self.show("Enter the code from Apple.", error: true); return }
                        self.view.endEditing(true); self.show("Checking your code…"); self.reply(.verificationCode(value))
                    }, for: .touchUpInside)
                    challenge.addArrangedSubview(next)
                    code.becomeFirstResponder()
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.reply(.cancel) }
        }
    }
    private func addChallengeButton(_ title: String, response: TwoFactorResponse) {
        let button = UIButton(type: .system); button.configuration = .tinted(); button.setTitle(title, for: .normal)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.show("Waiting for Apple…"); self?.reply(response) }, for: .touchUpInside)
        challenge.addArrangedSubview(button)
    }
}
#endif
