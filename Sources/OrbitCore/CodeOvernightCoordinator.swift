import Foundation

/// One phone invocation reconciles older artifacts before submitting new work.
/// Networking/Wi-Fi/lifetime belongs to the host; acceptance is not installation.
@MainActor public final class CodeOvernightCoordinator {
    private let catalog: CodeBuildCatalog
    private let client: CodeClient
    private let journal: CodeOvernightStore
    public init(catalog: CodeBuildCatalog, client: CodeClient, journal: CodeOvernightStore) {
        self.catalog = catalog; self.client = client; self.journal = journal
    }
    public func run(peer: String, invocationID: String, policy: CodeOvernightPolicy,
                    manually: Bool = false, at date: Date = Date(), calendar: Calendar = .current) async throws -> [CodeOvernightJob] {
        let capabilities: CodeOvernightCapabilities?
        do { capabilities = try await client.call(CodeRequest(.overnightCapabilities)).overnightCapabilities }
        catch {
            let original = error
            // Older peers can reject the new operation while still answering
            // the legacy read-only probe. Keep network errors distinguishable.
            if (try? await client.call(CodeRequest(.devices))) != nil { throw CodeFailure("Update Orbit Mac to use retained overnight builds.") }
            throw original
        }
        guard let capabilities, capabilities.version == 1, capabilities.installOnly, capabilities.retainedArtifacts, capabilities.reconciliation else {
            throw CodeFailure("Update Orbit Mac to use retained overnight builds.")
        }
        var remote = try await refresh()
        for job in remote where job.target.peerID == peer && job.hasActionableArtifact {
            try Task.checkCancellation()
            var request = CodeRequest(.overnightInstall); request.jobID = job.id
            try merge(try await client.call(request).overnightJobs ?? [])
        }
        remote = journal.jobs()
        var failure: Error?
        for app in catalog.apps(peer: peer) where app.nightlyEnabled == true {
            try Task.checkCancellation()
            guard manually || CodeNightlySchedule.isDue(app, at: date, calendar: calendar) else { continue }
            guard let device = app.deviceID ?? catalog.defaultDevice(peer: peer) else {
                failure = CodeFailure("Choose a target phone in Build Options."); continue
            }
            // No new source build while a previous artifact is actionable.
            if remote.contains(where: { $0.target.peerID == peer && $0.target.deviceID == device &&
                $0.target.project.path == app.project.path && $0.target.project.scheme == app.project.scheme &&
                ([.accepted, .building].contains($0.state) || $0.hasActionableArtifact) }) { continue }
            do {
                let target = CodeOvernightTarget(peerID: peer, deviceID: device, project: app.project, branch: app.branch, generation: policy.generation)
                let invocation = journal.invocations().first { $0.id == invocationID }
                var request = CodeRequest(.overnightSubmit)
                request.id = manually ? UUID().uuidString : CodeNightlySchedule.requestID(app: app, peer: peer + "|" + device + "|" + policy.generation, date: date, calendar: calendar)
                request.overnight = CodeOvernightSubmission(invocationID: invocationID, target: target, localDay: invocation?.localDay ?? "")
                let accepted = try await client.call(request).overnightJobs ?? []
                guard !accepted.isEmpty else { throw CodeFailure("The Mac did not confirm this overnight build.") }
                try merge(accepted)
                catalog.edit(key: app.key, peer: peer) { $0.lastNightlyAttempt = date; $0.nightlyFailure = nil }
                remote.append(contentsOf: accepted)
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error; catalog.edit(key: app.key, peer: peer) { $0.nightlyFailure = error.localizedDescription } }
        }
        if let failure { throw failure }
        return journal.jobs().filter { $0.target.peerID == peer }
    }
    @discardableResult public func refresh() async throws -> [CodeOvernightJob] {
        guard let jobs = try await client.call(CodeRequest(.overnightStatus)).overnightJobs else { throw CodeFailure("The Mac did not return overnight status.") }
        try merge(jobs)
        return jobs
    }
    private func merge(_ jobs: [CodeOvernightJob]) throws {
        for var job in jobs {
            job.synchronizedAt = Date()
            try journal.save(job)
            if let date = job.builtAt {
                let key = job.target.project.path + "\u{0}" + job.target.project.scheme
                catalog.edit(key: key, peer: job.target.peerID) {
                    if date > ($0.lastBuiltAt ?? .distantPast) { $0.lastBuiltAt = date; $0.commitHash = job.artifact?.commit }
                    if let installed = job.installedAt, installed > ($0.lastInstalledAt ?? .distantPast) { $0.lastInstalledAt = installed }
                }
            }
        }
    }
}
