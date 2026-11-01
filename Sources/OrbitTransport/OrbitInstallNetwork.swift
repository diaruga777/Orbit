import Foundation
import Network

/// Check the physical Wi-Fi route independently of the control pipe (including VPNs).
public enum OrbitInstallNetwork {
    public struct WiFiRequired: LocalizedError {
        public init() {}
        public var errorDescription: String? {
            "Connect this phone to Wi-Fi, then try again. Remote app installation can’t use cellular alone."
        }
    }

    public static func requireWiFi() async throws {
        let available = await withCheckedContinuation { continuation in
            let check = WiFiCheck(continuation)
            check.start()
        }
        try Task.checkCancellation()
        guard available else { throw WiFiRequired() }
    }
}

private final class WiFiCheck: @unchecked Sendable {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "Orbit.InstallWiFiCheck")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func start() {
        // Wait for the first observation; currentPath before start is not evidence.
        monitor.pathUpdateHandler = { [self] path in finish(path.status == .satisfied) }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [self] in finish(false) }
    }
    private func finish(_ available: Bool) {
        lock.lock()
        let pending = continuation; continuation = nil
        lock.unlock()
        guard let pending else { return }
        monitor.cancel()
        monitor.pathUpdateHandler = nil
        pending.resume(returning: available)
    }
}
