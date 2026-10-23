import Foundation

@main struct InstallerProbe {
    @MainActor static func main() async throws {
        let installer = OrbitToolInstaller()
        installer.start(script: #"""
        set -e
        stty -echo
        printf 'Synthetic challenge: '
        read -r answer < /dev/tty
        [[ "$answer" == 'synthetic-password' ]]
        printf '\nResponse received; secret=%s\n' "$answer"
        """#)
        for _ in 0..<100 {
            if installer.output.contains("Synthetic challenge:") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard installer.running, installer.output.contains("Synthetic challenge:") else { fatalError("No interactive terminal challenge") }
        installer.response = "synthetic-password"; installer.send()
        for _ in 0..<100 {
            if !installer.running { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !installer.running, installer.succeeded else { fatalError("Terminal did not accept /dev/tty response: \(installer.output)") }
        guard !installer.output.contains("synthetic-password"), installer.response.isEmpty else { fatalError("Response was retained in terminal output") }
        print("Synthetic installer challenge passed; no Apple or system installer commands ran.")
    }
}
