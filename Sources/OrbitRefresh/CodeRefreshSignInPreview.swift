#if DEBUG && os(iOS) && targetEnvironment(simulator)
import UIKit
import SideSign
import OrbitCore

/// Inert UI acceptance fixture: never contacts Apple/helpers or reads Keychain.
@MainActor public enum CodeRefreshSignInPreview {
    public static func make(scenario: String) -> UIViewController {
        let root = UIViewController(); root.view.backgroundColor = .systemBackground
        let result = UILabel(); result.text = "Sign-in fixture ready"; result.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(result)
        NSLayoutConstraint.activate([result.centerXAnchor.constraint(equalTo: root.view.centerXAnchor), result.centerYAnchor.constraint(equalTo: root.view.centerYAnchor)])
        let form = CodeRefreshSignInController(service: Fixture(scenario: scenario), server: CodeRefreshSignInInput.defaultServer) {
            result.text = "Account ready"
        }
        let navigation = UINavigationController(rootViewController: form); navigation.modalPresentationStyle = .formSheet
        // Present after the root joins a window, as in the real Refresh flow.
        Task { @MainActor in
            while root.view.window == nil { try? await Task.sleep(for: .milliseconds(20)) }
            root.present(navigation, animated: false)
        }
        return root
    }
    private actor Fixture: CodeRefreshSignInService {
        let scenario: String
        var attempts = 0
        var selections = 0
        init(scenario: String) { self.scenario = scenario }
        func signIn(appleID: String, password: String, anisetteURL: URL, rememberPassword: Bool,
                    verify: @escaping DeveloperPortal.VerificationHandler) async throws -> [Team] {
            attempts += 1
            guard anisetteURL == CodeRefreshSignInInput.defaultServer, appleID == "person@example.test", password == "fixture-password" else {
                throw CodeFailure("Unexpected fixture input.")
            }
            if scenario == "remember" && !rememberPassword { throw CodeFailure("Remember password was not passed to sign-in.") }
            try await Task.sleep(for: .milliseconds(600))
            if scenario == "error" || (scenario == "retry" && attempts == 1) { throw CodeFailure("Couldn’t sign in. Check your details and try again.") }
            if scenario == "verification" || scenario == "verification-error" {
                guard case .requestTrustedDevice = try await verify(.selectDeliveryMethod(preferredMode: .trustedDevice,
                    phoneNumbers: [.init(id: "fixture", number: "••• 42")])) else { throw CancellationError() }
                var response = try await verify(.trustedDevice())
                if case .verificationCode("000000") = response { response = try await verify(.trustedDevice(error: "That code didn’t work. Try again.")) }
                guard case .verificationCode("123456") = response else { throw CancellationError() }
                if scenario == "verification-error" { throw CodeFailure("Apple couldn’t finish sign-in. Try again.") }
            }
            if scenario == "empty-teams" { return [] }
            let personal = Team(identifier: "FIXTURE", name: "Example", type: .free)
            return scenario == "teams" || scenario == "team-error" ? [personal, Team(identifier: "SECOND", name: "Other Team", type: .organization)] : [personal]
        }
        func select(_ team: Team) async throws {
            selections += 1
            if scenario == "team-error" && selections == 1 { throw CodeFailure("Couldn’t save your team. Try again.") }
        }
    }
}
#endif
