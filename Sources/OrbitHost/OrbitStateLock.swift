import Foundation
import Darwin
import OrbitCore

/// Claim the state before any build journal/profile recovery. The Unix socket
/// alone is too late: service initialization also reconciles interrupted work.
final class OrbitStateLock: @unchecked Sendable {
    private let descriptor: Int32
    init(root: URL) throws {
        let descriptor = open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw CodeFailure("Could not lock Orbit’s state directory.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw CodeFailure("Orbit Mac is already running for this state directory.") }
        self.descriptor = descriptor
    }
    deinit { Darwin.close(descriptor) }
}
