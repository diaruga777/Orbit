#if os(iOS)
import BackgroundTasks
import Foundation

/// The scheduler boundary lets Simulator tests deliver launches and expirations
/// without depending on system scheduling or contacting a Mac.
@MainActor protocol CodeBuildBackgroundTask: AnyObject {
    var progress: Progress { get }
    var expirationHandler: (() -> Void)? { get set }
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}
extension BGContinuedProcessingTask: CodeBuildBackgroundTask {}

@MainActor protocol CodeBuildBackgroundScheduling {
    func register(identifier: String, handler: @escaping @MainActor (any CodeBuildBackgroundTask) -> Void)
    func submit(identifier: String, title: String) throws
    func cancel(identifier: String)
}

@MainActor final class CodeBuildSystemScheduler: CodeBuildBackgroundScheduling {
    func register(identifier: String, handler: @escaping @MainActor (any CodeBuildBackgroundTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { handler(task) }
        }
    }
    func submit(identifier: String, title: String) throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Building on your Mac…")
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
    }
    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
#endif
