#if os(iOS) && DEBUG
import UIKit
import CryptoKit
import OrbitCore

/// Simulator-only fixture for layout and keyboard tests. It never connects to
/// a Mac, uses no shared pairing state, and cannot build or publish anything.
@MainActor public enum CodeEditorPreview {
    public static func make(reset: Bool, workspace: Bool = false) throws -> UIViewController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitEditorUITests")
        if reset { try? FileManager.default.removeItem(at: root) }
        let drafts = try CodeDraftStore(root: root)
        let defaults = UserDefaults(suiteName: "OrbitEditorUITests")!
        if reset { defaults.removePersistentDomain(forName: "OrbitEditorUITests") }
        if !workspace && reset { defaults.set("/Preview/Welcome.swift", forKey: "Code.lastFile.preview") }
        let files = PreviewFiles(stateURL: root.appendingPathComponent("RemoteBuild.json"))
        let environment = CodeEnvironment(client: CodeClient { await files.handle($0) }, drafts: drafts, defaults: defaults,
            browse: { path, _, _ in
                if ProcessInfo.processInfo.arguments.contains("--browser-failure") { throw CodeFailure("Preview Mac is offline.") }
                let entries: [(String, Bool)]
                switch path {
                case nil: entries = [("/Preview/Sample.xcodeproj", true), ("/Other/Other.xcworkspace", true)]
                case "/Preview": entries = [("/Preview/Sample.xcodeproj", true), ("/Preview/Sources", true), ("/Preview/Welcome.swift", false)]
                case "/Preview/Sources": entries = [("/Preview/Sources/Detail.swift", false)]
                case "/Other": entries = [("/Other/Other.xcworkspace", true), ("/Other/Other.swift", false)]
                default: entries = []
                }
                return CodeBrowserPage(items: entries.map { CodeBrowserItem(path: $0.0, name: ($0.0 as NSString).lastPathComponent, directory: $0.1) }, next: nil)
            },
            pairing: { UIViewController() }, peerID: { "preview" })
        return CodeTabsController(environment: environment)
    }
}
private actor PreviewFiles {
    private static let iconPNG: Data? = {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let names = primary["CFBundleIconFiles"] as? [String], let name = names.last else { return nil }
        return UIImage(named: name)?.pngData()
    }()
    private var buildStartedAt: Date?
    private var handoffAcknowledgedAt: Date?
    private let stateURL: URL
    private struct BuildState: Codable { var startedAt: Date?; var acknowledgedAt: Date? }
    init(stateURL: URL) {
        self.stateURL = stateURL
        if ProcessInfo.processInfo.arguments.contains("--build-self-update"),
           let state = try? JSONDecoder().decode(BuildState.self, from: Data(contentsOf: stateURL)) {
            buildStartedAt = state.startedAt; handoffAcknowledgedAt = state.acknowledgedAt
        }
    }
    private func persistBuild() {
        try? JSONEncoder().encode(BuildState(startedAt: buildStartedAt, acknowledgedAt: handoffAcknowledgedAt)).write(to: stateURL, options: .atomic)
    }
    private var injectConflict = ProcessInfo.processInfo.arguments.contains("--save-conflict")
    var text = """
    import UIKit

    // A small change, wherever you are.
    final class WelcomeViewController: UIViewController {
        private let titleLabel = UILabel()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            titleLabel.text = "Hello, Orbit"
            titleLabel.font = .systemFont(ofSize: 28)
            titleLabel.textColor = .systemIndigo
            view.addSubview(titleLabel)
        }

        func greeting(for name: String) -> String {
            return "Welcome, \\(name)"
        }
    }
    """
    private func selfUpdateJob() -> CodeJob {
        var job = CodeJob(id: "preview-build", title: "Build & Run")
        job.startedAt = buildStartedAt ?? Date()
        let elapsed = Date().timeIntervalSince(job.startedAt)
        if elapsed >= 3 {
            job.installHandoff = CodeInstallHandoff(token: "preview-install", acknowledged: handoffAcknowledgedAt != nil)
            job.progress = CodeJobProgress(stage: "Build complete — ready to update Orbit", start: 0.80, end: 0.80, estimatedSeconds: 1, reportedFraction: 0.80)
        }
        if let handoffAcknowledgedAt {
            job.log = "Installation permitted only after the activity handoff was acknowledged."
            if Date().timeIntervalSince(handoffAcknowledgedAt) > 10 { job.state = .succeeded }
        }
        return job
    }
    func handle(_ data: Data) async -> Data {
        var response = CodeResponse()
        do {
            let request = try JSONDecoder().decode(CodeRequest.self, from: data)
            if ProcessInfo.processInfo.arguments.contains("--build-offline"), [.devices, .apps, .schemes, .job].contains(request.operation) { throw CodeFailure("Preview Mac is offline.") }
            let version = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            switch request.operation {
            case .devices:
                response.supportsOvernightBuilds = true
                response.devices = [CodeDevice(id: "preview-phone", name: "Preview iPhone")]
                return try JSONEncoder().encode(response)
            case .apps:
                if ProcessInfo.processInfo.arguments.contains("--build-discovery-delay"), let scheme = request.project?.scheme, scheme != "Sample" {
                    try await Task.sleep(for: .seconds(2))
                    if scheme == "Broken" { throw CodeFailure("Preview scheme could not resolve its dependencies.") }
                    if scheme == "SampleLibrary" { response.apps = []; return try JSONEncoder().encode(response) }
                }
                let schemes = request.project.map { [$0.scheme] } ?? ["Sample", "SampleAlias", "SampleCompanion"]
                response.apps = schemes.filter { !$0.hasSuffix("Tests") }.map {
                    var app = CodeBuildApp(project: CodeProject(path: request.path, scheme: $0), name: $0, bundleID: "preview." + ($0 == "SampleAlias" ? "Sample" : $0))
                    // Real app artwork exercises the same wire/cache path as discovery.
                    app.iconPNG = Self.iconPNG
                    return app
                }
                return try JSONEncoder().encode(response)
            case .branches:
                response.branches = ["main", "feature/preview"]
                return try JSONEncoder().encode(response)
            case .runOnDevice:
                guard request.deviceBuild?.branch == "main", request.deviceBuild?.deviceID == "preview-phone" else { throw CodeFailure("Unexpected preview build settings.") }
                if ProcessInfo.processInfo.arguments.contains("--build-start-delay") { try await Task.sleep(for: .seconds(5)) }
                buildStartedAt = Date(); handoffAcknowledgedAt = nil
                if ProcessInfo.processInfo.arguments.contains("--build-self-update") { persistBuild() }
                response.job = CodeJob(id: "preview-build", title: "Build & Run · " + (request.project?.scheme ?? ""), state: .running, log: "Preview build from main on Preview iPhone. No Mac command was executed.")
                response.job?.startedAt = buildStartedAt ?? Date()
                response.job?.progress = CodeJobProgress(stage: "Preparing checkout…", start: 0.05, end: 0.25, estimatedSeconds: 3)
                if ProcessInfo.processInfo.arguments.contains("--build-no-progress") { response.job?.progress = nil }
                return try JSONEncoder().encode(response)
            case .job:
                let flags = ProcessInfo.processInfo.arguments
                let duration: TimeInterval = flags.contains("--build-no-progress") ? 25 : flags.contains("--build-events") ? 18 : 6
                response.job = CodeJob(id: "preview-build", title: "Build & Run", state: Date().timeIntervalSince(buildStartedAt ?? .distantPast) > duration ? .succeeded : .running, log: "Preview build from main on Preview iPhone. No Mac command was executed.")
                response.job?.startedAt = buildStartedAt ?? Date()
                response.job?.progress = CodeJobProgress(stage: "Compiling on your Mac…", start: 0.25, end: 0.80, estimatedSeconds: 4, startedAt: buildStartedAt ?? Date())
                if flags.contains("--build-no-progress") { response.job?.progress = nil }
                if flags.contains("--build-events") {
                    let completed = Int(Date().timeIntervalSince(buildStartedAt ?? Date())) * 3
                    response.job?.progress = CodeJobProgress(stage: "Compile Feature.swift (arm64)", start: 0.25, end: 0.80,
                        estimatedSeconds: 1, reportedFraction: min(0.79, 0.25 + Double(completed) / 100))
                    response.job?.progress?.completedTasks = completed; response.job?.progress?.activeTasks = 2
                }
                if flags.contains("--build-self-update") {
                    response.job = selfUpdateJob()
                }
                if response.job?.state == .succeeded {
                    response.job?.builtAt = buildStartedAt?.addingTimeInterval(6)
                    response.job?.commitHash = "abc12345def67890"
                }
                return try JSONEncoder().encode(response)
            case .acknowledgeInstall:
                guard ProcessInfo.processInfo.arguments.contains("--build-self-update"), request.jobID == "preview-build",
                      request.handoffToken == "preview-install", buildStartedAt != nil else { throw CodeFailure("Invalid preview update handoff.") }
                handoffAcknowledgedAt = handoffAcknowledgedAt ?? Date(); persistBuild()
                response.job = selfUpdateJob()
                return try JSONEncoder().encode(response)
            case .schemes:
                response.schemes = ProcessInfo.processInfo.arguments.contains("--build-discovery-delay")
                    ? ["Sample", "SampleLibrary", "Broken", "SampleAlias", "SampleCompanion", "SampleTests"]
                    : ["Sample", "SampleAlias", "SampleCompanion", "SampleTests"]
                return try JSONEncoder().encode(response)
            case .open: break
            case .save:
                if injectConflict { text += "\n// Changed on Mac"; injectConflict = false; response.conflict = true }
                else if request.version == version { text = request.text } else { response.conflict = true }
            default: throw CodeFailure("Editor preview: Mac commands are disabled.")
            }
            response.document = CodeDocument(path: request.path, text: text, version: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
        } catch { response.error = error.localizedDescription }
        return try! JSONEncoder().encode(response)
    }
}
#endif
