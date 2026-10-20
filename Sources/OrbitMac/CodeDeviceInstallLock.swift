import Foundation

/// Shared by foreground Build & Run and durable overnight installation.
actor CodeDeviceInstallLock {
    static let shared = CodeDeviceInstallLock()
    private var owners: [String: UUID] = [:]
    func acquire(_ device: String) async throws -> UUID {
        while owners[device] != nil { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        let token = UUID(); owners[device] = token; return token
    }
    func release(_ device: String, token: UUID) { if owners[device] == token { owners[device] = nil } }
}
