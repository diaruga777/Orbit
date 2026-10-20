import Foundation

public enum CodeNightlySchedule {
    /// Only start new jobs between 1 and 6 AM in the phone's current time zone.
    public static func isOvernight(_ date: Date, calendar: Calendar = .current) -> Bool {
        (1..<6).contains(calendar.component(.hour, from: date))
    }
    public static func nextStart(after date: Date, calendar: Calendar = .current) -> Date {
        if isOvernight(date, calendar: calendar) { return date }
        return calendar.nextDate(after: date, matching: DateComponents(hour: 1), matchingPolicy: .nextTime) ?? date.addingTimeInterval(86400)
    }
    public static func isDue(_ app: CodeBuildApp, at date: Date, calendar: Calendar = .current) -> Bool {
        app.nightlyEnabled == true && isOvernight(date, calendar: calendar)
            && !(app.lastNightlyAttempt.map { calendar.isDate($0, inSameDayAs: date) } ?? false)
    }
    public static func requestID(app: CodeBuildApp, peer: String, date: Date, calendar: Calendar = .current) -> String {
        "nightly-" + Data((peer + "\u{0}" + app.key).utf8).base64EncodedString()
            + "-" + String(format: "%04d-%02d-%02d", calendar.component(.year, from: date), calendar.component(.month, from: date), calendar.component(.day, from: date))
    }
}

/// Submit the entire due set promptly. The Mac serializes accepted jobs, so
/// builds continue when iOS expires runtime or the phone disconnects.
@MainActor public final class CodeNightlyBuilds {
    private let catalog: CodeBuildCatalog
    private let client: CodeClient
    public init(catalog: CodeBuildCatalog, client: CodeClient) { self.catalog = catalog; self.client = client }
    public func run(peer: String, clock: () -> Date = { Date() }) async throws {
        let capability = try await client.call(CodeRequest(.devices))
        guard capability.supportsOvernightBuilds == true else { throw CodeFailure("Update Orbit Mac to use overnight builds.") }
        var failure: Error?
        for original in catalog.apps(peer: peer) where original.nightlyEnabled == true {
            try Task.checkCancellation()
            do {
                // Restore an accepted build before deciding whether today's job is due.
                if let id = original.jobID {
                    var request = CodeRequest(.job); request.jobID = id
                    if let job = try await client.call(request).job {
                        catalog.record(job, peer: peer)
                        if job.state == .running { continue }
                    }
                }
                guard let app = catalog.apps(peer: peer).first(where: { $0.key == original.key }),
                      CodeNightlySchedule.isDue(app, at: clock()) else { continue }
                guard let device = app.deviceID ?? catalog.defaultDevice(peer: peer) else {
                    catalog.edit(key: app.key, peer: peer) { $0.nightlyFailure = "Choose a target phone in Build Options." }
                    continue
                }
                let date = clock()
                var request = CodeRequest(.runOnDevice); request.project = app.project
                request.id = CodeNightlySchedule.requestID(app: app, peer: peer, date: date)
                var options = CodeDeviceBuild(branch: app.branch, deviceID: device)
                options.installOnly = true; request.deviceBuild = options
                // Stable IDs make a lost acknowledgement safe to retry, including after Mac restart.
                guard let job = try await client.call(request).job else { throw CodeFailure("The Mac did not confirm the overnight build.") }
                catalog.edit(key: app.key, peer: peer) {
                    $0.jobID = job.id; $0.lastNightlyAttempt = date; $0.nightlyFailure = nil
                }
                catalog.record(job, peer: peer)
            } catch is CancellationError { throw CancellationError() }
            catch {
                catalog.edit(key: original.key, peer: peer) { $0.nightlyFailure = error.localizedDescription }
                failure = error
            }
        }
        if let failure { throw failure }
    }
}
