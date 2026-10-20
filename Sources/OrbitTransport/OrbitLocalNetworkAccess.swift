import Foundation
import Network
import OrbitWire

/// Network.framework participates in the local-network consent flow and reports
/// its denial explicitly. A BSD socket alone only returns "no route to host".
final class OrbitLocalNetworkAccess: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "orbit.local-network-access")
    private var continuation: CheckedContinuation<Void, Error>?
    private var denied = false
    private var completed = false
    private var timer: DispatchWorkItem?

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func check() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !completed else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    connection.stateUpdateHandler = { [weak self] state in self?.changed(state) }
                    let timer = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.finish(self.denied ? OrbitTransportError.localNetworkDenied :
                            OrbitTransportError.unreachable("The Mac did not answer. Check that both devices are on the same Wi-Fi, or connected to the same Tailscale network."))
                    }
                    self.timer = timer
                    queue.asyncAfter(deadline: .now() + 20, execute: timer)
                    connection.start(queue: queue)
                }
            }
        } onCancel: {
            self.queue.async { self.finish(CancellationError()) }
        }
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready: finish(nil)
        case .waiting:
            denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
            // Keep waiting while the system asks the user. Allowing access
            // resumes this same attempt rather than reporting a false failure.
        case .failed(let error):
            finish(connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                ? OrbitTransportError.localNetworkDenied : OrbitTransportError.unreachable(error.localizedDescription))
        case .cancelled: finish(CancellationError())
        default: break
        }
    }

    private func finish(_ error: Error?) {
        guard !completed else { return }
        completed = true
        timer?.cancel(); timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) }
        else { pending?.resume() }
    }
}
