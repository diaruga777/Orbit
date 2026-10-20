import Foundation
import Darwin
import OrbitCore

/// No shell interpolation. Output goes to disk so a full pipe cannot stall a build.
public final class CodeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p { stop(p) }
    }
    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if getpgid(pid) == pid { kill(-pid, SIGINT); kill(-pid, SIGTERM) }
        else { process.interrupt(); process.terminate() }
    }
    public func run(_ executable: String, _ arguments: [String], directory: String,
                    log: URL, timeout: TimeInterval = 3600, onTick: (@Sendable () async -> Void)? = nil) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await Task.detached { [self] in
                if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
                let output = try FileHandle(forWritingTo: log)
                defer { try? output.close() }
                try output.seekToEnd()
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                // Isolate the command tree so Cancel also stops xcodebuild and
                // upload subprocesses launched by asc, without affecting Xcode.
                p.arguments = ["-c", "import os,sys; os.setsid() if os.getpgrp() != os.getpid() else None; os.execv(sys.argv[1], sys.argv[1:])", executable] + arguments; p.currentDirectoryURL = URL(fileURLWithPath: directory)
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "")
                p.environment = environment; p.standardOutput = output; p.standardError = output
                try lock.withCriticalScope {
                    guard !cancelled else { throw CancellationError() }
                    try p.run(); process = p
                }
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                while p.isRunning {
                    await onTick?()
                    if ProcessInfo.processInfo.systemUptime > deadline { stop(p); throw CodeFailure("The command timed out. See the build log.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                await onTick?()
                // isRunning is already false. A second waitUntilExit can stall
                // Foundation’s run loop after short, sequential commands.
                lock.withCriticalScope { process = nil }
                if lock.withCriticalScope({ cancelled }) { throw CancellationError() }
                return p.terminationStatus
            }.value
        } onCancel: { self.cancel() }
    }
}
extension NSLock {
    func withCriticalScope<T>(_ operation: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try operation() }
}
