import Foundation
import OrbitCore

public actor CodeService {
    private let files = CodeFiles()
    private let jobs: CodeJobs
    public let reverseFlows: CodeReverseFlowHub?
    private let endpoints: CodeEndpointEnrollmentService?
    private let overnight: CodeOvernightService
    private let root: URL
    private let checkAccess: @Sendable (String) async throws -> Void
    private var language: Task<CodeLanguageServer, Error>?
    private var projectKey: String?
    private var intelligenceTail: Task<Void, Never>?
    private var savedReplies: [String: (Data, Data)] = [:]
    public init(root: URL, installBundleID: String? = nil, installHelper: URL? = nil, checkAccess: @escaping @Sendable (String) async throws -> Void = { _ in }) throws {
        self.root = root; self.checkAccess = checkAccess
        let builds = try CodeJobs(root: root.appendingPathComponent("Jobs")); jobs = builds
        let journal = try CodeOvernightStore(root: root.appendingPathComponent("Overnight"))
        if let installBundleID {
            let directory = root.appendingPathComponent("Endpoints", isDirectory: true)
            let enrollment = try CodeEndpointEnrollmentService(root: directory,
                access: CodeAppleEndpointContainer(root: directory.appendingPathComponent("Scratch"), bundleID: installBundleID))
            endpoints = enrollment
            reverseFlows = CodeReverseFlowHub(lookup: { id, peer in
                guard let binding = try await enrollment.status(peer: peer).first(where: { $0.id == id }) else { throw CodeFailure("This phone’s authorization was removed.") }
                return binding
            }, record: { try? journal.event($0) })
        } else { endpoints = nil; reverseFlows = nil }
        let remote: CodeReverseInstallerConfiguration?
        if let reverseFlows, let installHelper, let installBundleID { remote = CodeReverseInstallerConfiguration(hub: reverseFlows, helper: installHelper, forwarderBundleID: installBundleID, diagnostics: root.appendingPathComponent("Overnight")) }
        else { remote = nil }
        overnight = try CodeOvernightService(root: root, builds: builds, remote: remote, journal: journal)
    }
    public func revokeEndpointAuthorizations() async throws { try await endpoints?.revokeAll(); await reverseFlows?.revoke() }
    public func handle(_ data: Data, authenticatedPeerID: String? = nil) async -> Data {
        var response = CodeResponse()
        do {
            guard data.count <= CodeWire.maxPayloadBytes else { throw CodeFailure("Request too large.") }
            let request = try JSONDecoder().decode(CodeRequest.self, from: data)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let canonical = try encoder.encode(request)
            if let previous = savedReplies[request.id] {
                guard previous.0 == canonical else { throw CodeFailure("A request ID was reused with different content.") }
                return previous.1
            }
            switch request.operation {
            case .endpointReadyBegin, .endpointReadyFinish, .endpointPoll, .endpointStop, .endpointBegin, .endpointFinish, .endpointStatus, .endpointRevoke, .job, .cancel, .devices, .acknowledgeInstall, .overnightCapabilities, .overnightStatus, .overnightInstall, .overnightCancel, .overnightDiagnostics: break
            default:
                let path = request.overnight?.target.project.path ?? request.project?.path ?? request.path
                if path.hasPrefix("/") { try await checkAccess(URL(fileURLWithPath: path).deletingLastPathComponent().path) }
            }
            switch request.operation {
            case .endpointReadyBegin, .endpointReadyFinish, .endpointPoll, .endpointStop:
                guard let hub = reverseFlows, let peer = authenticatedPeerID, let control = request.reverse else { throw CodeFailure("Phone installation readiness is unavailable.") }
                switch request.operation {
                case .endpointReadyBegin: response.reverseChallenge = try await hub.begin(control, peer: peer)
                case .endpointReadyFinish: response.reverseReadiness = try await hub.finish(control, peer: peer)
                case .endpointPoll: response.reverseFlows = try await hub.poll(control, peer: peer)
                default: await hub.stop(control, peer: peer)
                }
            case .endpointBegin, .endpointFinish, .endpointStatus, .endpointRevoke:
                guard let endpoints, let peer = authenticatedPeerID, !peer.isEmpty else { throw CodeFailure("Update Orbit Mac and reconnect before authorizing this phone.") }
                switch request.operation {
                case .endpointBegin:
                    guard let enrollment = request.endpoint else { throw CodeFailure("Choose a phone to authorize.") }
                    response.endpointChallenge = try await endpoints.begin(enrollment, peer: peer)
                case .endpointFinish:
                    guard let enrollment = request.endpoint else { throw CodeFailure("Start phone authorization again.") }
                    response.endpointBindings = [try await endpoints.finish(id: enrollment.id, peer: peer)]
                case .endpointRevoke:
                    guard let enrollment = request.endpoint else { throw CodeFailure("Choose a phone authorization to remove.") }
                    try await endpoints.revoke(id: enrollment.id, peer: peer)
                    await reverseFlows?.revoke(bindingID: enrollment.id)
                    response.endpointBindings = try await endpoints.status(peer: peer)
                default: response.endpointBindings = try await endpoints.status(peer: peer)
                }
            case .overnightDiagnostics: response.overnightDiagnostics = try await overnight.diagnostics()
            case .overnightCapabilities: response.overnightCapabilities = await overnight.capabilities()
            case .overnightSubmit: response.overnightJobs = [try await overnight.submit(request)]
            case .overnightStatus: response.overnightJobs = try await overnight.status()
            case .overnightInstall: response.overnightJobs = [try await overnight.retryInstall(request.jobID)]
            case .overnightCancel: response.overnightJobs = [try await overnight.cancel(request.jobID)]
            case .open:
                let document = try files.open(request.path)
                if document.version != request.version { response.document = document }
            case .save:
                let result = try files.save(path: request.path, text: request.text, expected: request.version)
                response.document = result.0; response.conflict = result.1
            case .schemes:
                let path = request.path
                guard path.hasPrefix("/"), ["xcworkspace", "xcodeproj"].contains(URL(fileURLWithPath: path).pathExtension) else { throw CodeFailure("Choose an Xcode project or workspace.") }
                response.schemes = try await CodeDeviceSupport.schemes(path: path, root: root)
            case .apps:
                guard request.path.hasPrefix("/"), ["xcworkspace", "xcodeproj"].contains(URL(fileURLWithPath: request.path).pathExtension) else { throw CodeFailure("Choose an Xcode project or workspace.") }
                response.apps = await jobs.history(try await CodeDeviceSupport.apps(path: request.path, scheme: request.project?.scheme, root: root))
            case .devices:
                response.supportsOvernightBuilds = true
                response.devices = try await CodeDeviceSupport.devices(root: root)
            case .branches: response.branches = try await CodeDeviceSupport.branches(path: request.path, root: root)
            case .prepare, .build, .deploy, .runOnDevice:
                response.job = try await jobs.start(request)
                if request.operation == .prepare { language?.cancel(); language = nil; projectKey = nil }
            case .job: response.job = try await jobs.status(request.jobID)
            case .cancel: response.job = try await jobs.cancel(request.jobID)
            case .acknowledgeInstall: response.job = try await jobs.acknowledgeInstall(request.jobID, token: request.handoffToken)
            case .analyze, .complete:
                guard let project = request.project, !project.scheme.isEmpty, request.text.utf8.count <= CodeWire.maxFileBytes else { throw CodeFailure("Select a project and scheme to enable Mac code intelligence.") }
                let key = project.path + "\u{0}" + project.scheme
                if language == nil || projectKey != key {
                    let derived = await jobs.derivedData(project)
                    projectKey = key
                    language = Task {
                        let server = try CodeLanguageServer(project: project, derivedData: derived, logs: root)
                        try await server.initialize(project: project)
                        return server
                    }
                }
                let server: CodeLanguageServer
                do { server = try await language!.value }
                catch { language = nil; throw error }
                // Keep each buffer update and its response together. Actors may
                // reenter while awaiting LSP, including requests from both apps.
                let previous = intelligenceTail
                let operation = Task<CodeResponse, Error> {
                    await previous?.value
                    try server.update(path: request.path, text: request.text, version: request.bufferVersion)
                    var reply = CodeResponse()
                    if request.operation == .complete {
                        reply.completions = try await server.complete(path: request.path, position: request.position ?? CodePosition(line: 0, character: 0))
                    } else { reply.diagnostics = try await server.diagnostics(path: request.path) }
                    return reply
                }
                intelligenceTail = Task { _ = try? await operation.value }
                response = try await operation.value
            }
            let encoded = try JSONEncoder().encode(response)
            if request.operation == .save {
                if savedReplies.count > 64 { savedReplies.removeAll() }
                savedReplies[request.id] = (canonical, encoded)
            }
            return encoded
        } catch { response.error = error.localizedDescription }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}
