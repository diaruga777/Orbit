import Foundation

/// Stage boundaries are measured; movement within a stage is a bounded estimate.
/// Optional on CodeJob so jobs from older companions and persisted logs still decode.
public struct CodeJobProgress: Codable, Equatable, Sendable {
    public var stage: String
    public var start: Double
    public var end: Double
    public var startedAt: Date
    public var estimatedSeconds: Double
    public var stoppedAt: Date?
    /// Event-driven progress has a fixed value until more work actually finishes.
    public var reportedFraction: Double?
    public var completedTasks: Int?
    public var activeTasks: Int?

    public init(stage: String, start: Double, end: Double, estimatedSeconds: Double, startedAt: Date = Date(), reportedFraction: Double? = nil) {
        self.stage = stage; self.start = start; self.end = end
        self.estimatedSeconds = estimatedSeconds; self.startedAt = startedAt; self.reportedFraction = reportedFraction
    }
    public func fraction(at date: Date = Date()) -> Double {
        if let reportedFraction { return min(0.99, max(0, reportedFraction)) }
        let elapsed = max(0, (stoppedAt ?? date).timeIntervalSince(startedAt))
        let movement = 0.9 * (1 - exp(-elapsed / max(1, estimatedSeconds)))
        return min(0.99, max(0, start + (end - start) * movement))
    }
}

extension CodeJob {
    /// Attach an elapsed-time estimate once, retaining its clock and terminal value
    /// across status replies from companions that don't send stage metadata.
    public func estimatingProgress(from previous: CodeJob? = nil, at date: Date = Date()) -> CodeJob {
        var value = self
        if value.progress == nil {
            value.progress = (previous?.id == id ? previous?.progress : nil) ?? CodeJobProgress(
                stage: "Building on your Mac…", start: 0.05, end: 0.95,
                estimatedSeconds: title.contains("Deploy") ? 900 : 120,
                startedAt: min(startedAt, date))
        }
        if state != .running, value.progress?.stoppedAt == nil { value.progress?.stoppedAt = date }
        return value
    }
    public func progressFraction(at date: Date = Date()) -> Double {
        if state == .succeeded { return 1 }
        if let progress { return progress.fraction(at: date) }
        guard state == .running else { return 0.05 }
        return estimatingProgress(at: date).progress?.fraction(at: date) ?? 0.05
    }
    public var progressDetail: String? {
        guard let count = progress?.completedTasks else { return nil }
        let active = progress?.activeTasks ?? 0
        return "\(count) build tasks completed" + (active > 0 ? " · \(active) running" : "")
    }
    public var progressStage: String { progress?.stage ?? "Building on your Mac…" }
}
