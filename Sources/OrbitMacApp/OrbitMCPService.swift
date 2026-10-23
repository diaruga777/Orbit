import Foundation
import OrbitHost

/// The HTTP adapter lives exactly as long as the Mac app. Stdio hosts can still
/// launch their own adapter against the same owner-only control socket.
@MainActor final class OrbitMCPService {
    private var process: Process?
    private(set) var status = "Starting local tools…"
    func startIfNeeded() {
        guard process?.isRunning != true else { return }
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AgentTools/bin/orbit")
        guard FileManager.default.fileExists(atPath: cli.path) else { status = "Local tools are missing from this Orbit app."; return }
        // /usr/bin/python3 may be Apple’s first-run shim on a clean Mac.
        // Wait for tool setup instead of opening a second system installer.
        let python = OrbitSetup.pythonExecutable
        if python == "/usr/bin/python3" {
            guard FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3") ||
                  FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3") else { return }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [cli.path, "mcp-http", String(ProcessInfo.processInfo.processIdentifier)]
        var environment = ProcessInfo.processInfo.environment
        environment["ORBIT_HOME"] = OrbitPaths.root.path
        task.environment = environment
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        do { try task.run(); process = task; status = "Local tools ready" }
        catch { status = "Install Mac tools to start Orbit’s local tools." }
    }
    func stop() { process?.terminate(); process = nil }
    deinit { process?.terminate() }
}
