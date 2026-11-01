import Foundation

extension CodeJob {
    /// The Host catalog has durable install jobs as well as direct build jobs.
    /// Keep compilation progress, but never call a compiled artifact installed.
    public static func targetStatus(_ data: Data) throws -> CodeJob {
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(CodeJob.self, from: data) { return direct }
        struct MacStatus: Decodable { var platform: String?; var id: String; var state: String; var title: String?; var log: String?; var failureMessage: String?; var progress: CodeJobProgress? }
        if let mac = try? decoder.decode(MacStatus.self, from: data), mac.platform == "macOS", mac.state == "unknownCompletion" {
            var job = CodeJob(id: mac.id, title: mac.title ?? "Mac build", log: mac.log ?? "")
            job.failureMessage = mac.failureMessage; job.progress = mac.progress
            return job
        }
        let retained = try decoder.decode(CodeOvernightJob.self, from: data)
        struct Details: Decodable { var log: String?; var compilation: CodeJob? }
        let details = try decoder.decode(Details.self, from: data)
        return retained.monitoring(compilation: details.compilation, log: details.log ?? "")
    }
}

extension CodeOvernightJob {
    public func monitoring(compilation: CodeJob? = nil, log: String = "") -> CodeJob {
        var job = CodeJob(id: id, title: "Build & Install · " + target.project.scheme)
        job.installHandoff = installHandoff
        job.startedAt = acceptedAt; job.builtAt = builtAt; job.log = log
        job.failureMessage = error?.recovery
        switch state {
        case .succeeded: job.state = .succeeded
        case .failed: job.state = .failed
        case .cancelled: job.state = .cancelled
        default: job.state = .running
        }
        switch state {
        case .accepted: job.progress = CodeJobProgress(stage: "Waiting for your Mac…", start: 0.05, end: 0.05, estimatedSeconds: 1)
        case .building: job.progress = compilation?.progress
        case .waitingForPhone: job.progress = CodeJobProgress(stage: "Build complete · Waiting for your phone…", start: 0.80, end: 0.80, estimatedSeconds: 1)
        case .installing: job.progress = CodeJobProgress(stage: "Installing on your phone…", start: 0.80, end: 0.93, estimatedSeconds: 40)
        case .unknownCompletion: job.progress = CodeJobProgress(stage: "Checking installation on your phone…", start: 0.93, end: 0.93, estimatedSeconds: 1)
        default: job.progress = compilation?.progress
        }
        if job.state != .running { job.progress?.stoppedAt = Date() }
        return job
    }
}
