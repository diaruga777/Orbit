import Foundation
import SwiftUI

/// A private, interactive pseudo-terminal for the upstream installer. No terminal
/// transcript or responses are written to setup state, diagnostics or build logs.
@MainActor final class OrbitToolInstaller: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var output = ""
    @Published private(set) var succeeded = false
    @Published var response = ""
    private var process: Process?
    private var input: Pipe?
    private var stream: Pipe?
    private var responses: [String] = []

    func start(xcodeVersion: String?) {
        if let xcodeVersion {
            guard xcodeVersion.count < 16, xcodeVersion.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return }
            start(script: Self.installScript.replacingOccurrences(of: "--latest", with: xcodeVersion))
        } else {
            start(script: Self.installScript.replacingOccurrences(of: "xcodes install --latest --select", with: "print 'Xcode tools changed. Check again and restart setup.'; exit 1"))
        }
    }
    // Internal injection is used only by the synthetic terminal probe.
    func start(script: String) {
        guard !running else { return }
        output = "Preparing Mac tools…\n"; succeeded = false; responses = []
        let task = Process(), input = Pipe(), stream = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        task.arguments = ["-q", "/dev/null", "/bin/zsh", "-c", script]
        task.standardInput = input; task.standardOutput = stream; task.standardError = stream
        // Inherited CI credentials must never reach the interactive installer.
        var environment = ProcessInfo.processInfo.environment
        for key in ["XCODES_PASSWORD", "XCODES_USERNAME", "FASTLANE_SESSION", "SUDO_ASKPASS", "CI", "NONINTERACTIVE"] { environment.removeValue(forKey: key) }
        task.environment = environment
        stream.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        task.terminationHandler = { [weak self] task in
            Task { @MainActor in
                guard let self else { return }
                self.stream?.fileHandleForReading.readabilityHandler = nil
                self.running = false; self.succeeded = task.terminationStatus == 0
                self.output += self.succeeded ? "\nMac tools installed.\n" : "\nInstallation stopped. You can try again.\n"
                self.response = ""; self.process = nil; self.input = nil; self.stream = nil
            }
        }
        do { try task.run(); process = task; self.input = input; self.stream = stream; running = true }
        catch { stream.fileHandleForReading.readabilityHandler = nil; output = "Couldn’t start the installer. " + error.localizedDescription }
    }
    private func receive(_ data: Data) {
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        var transcript = output + text
        for value in responses where !value.isEmpty { transcript = transcript.replacingOccurrences(of: value, with: "••••") }
        output = String(transcript.suffix(16000))
    }
    func send() {
        guard running, !response.contains("\n"), !response.contains("\r") else { return }
        let value = response; response = ""
        if !value.isEmpty { responses.append(value) }
        // Terminal echo is disabled in the installer before any prompt.
        try? input?.fileHandleForWriting.write(contentsOf: Data((value + "\n").utf8))
    }
    func cancel() {
        try? input?.fileHandleForWriting.write(contentsOf: Data([3]))
    }

    static let installScript = #"""
    set -e -o pipefail
    stty -echo
    export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    needs_xcode=0
    /usr/bin/xcrun --sdk iphoneos --show-sdk-version 2>/dev/null | /usr/bin/awk -F. 'NR==1 {ok=($1 >= 26)} END {exit !ok}' || needs_xcode=1
    needs_python=0
    /usr/bin/python3 --version >/dev/null 2>&1 || needs_python=1
    if [[ "$needs_xcode" == 1 || "$needs_python" == 1 ]]; then
      if ! command -v brew >/dev/null; then
        print 'Installing Homebrew. Approve its prompts below.'
        installer=$(/usr/bin/mktemp /tmp/orbit-homebrew.XXXXXX)
        trap '/bin/rm -f "$installer"' EXIT
        /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"
        /bin/bash "$installer"
      fi
      if [[ "$needs_xcode" == 1 ]]; then
        brew install xcodesorg/made/xcodes
        print 'Sign in to Apple below when xcodes asks. Your password stays in your Keychain.'
        xcodes install --latest --select
      fi
      if [[ "$needs_python" == 1 ]]; then
        brew install python
      fi
    fi
    print 'Finishing Xcode setup. macOS may ask for your Mac password.'
    sudo /usr/bin/xcodebuild -runFirstLaunch
    /usr/bin/xcodebuild -downloadPlatform iOS
    /usr/bin/xcodebuild -checkFirstLaunchStatus
    /usr/bin/xcrun --sdk iphoneos --show-sdk-version
    python3 --version
    """#
}
