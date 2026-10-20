import Foundation

struct CodeBuildEventSnapshot: Equatable, Sendable {
    var completed: Int = 0
    var active: Int = 0
    var operation: String = "Preparing build…"
    var buildSucceeded = false
    /// Xcode can discover additional work during a build. This is work-based,
    /// not a claim that task count is a percentage of remaining wall-clock time.
    func fraction(expectedTasks: Int?) -> Double {
        if buildSucceeded { return 1 }
        if let expectedTasks, expectedTasks > 0 { return min(0.98, Double(completed) / Double(expectedTasks)) }
        return Double(completed) / Double(completed + 32)
    }
}

/// Parses xcodebuild's supported result stream, counting command-invocation
/// sections only (not container logs, warnings, or arbitrary console output).
struct CodeBuildEventParser {
    private var pending = Data()
    private var skippingLine = false
    private var action = 0
    private var seen: Set<String> = []
    private var finished: Set<String> = []
    private var active: [String: String] = [:]
    private(set) var snapshot = CodeBuildEventSnapshot()
    private let maxLineBytes = 1024 * 1024

    mutating func append(_ data: Data) {
        // Process fragments without retaining an unbounded diagnostic/log line.
        for fragment in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
            if fragment.offset > 0 {
                if !skippingLine { consume(pending) }
                pending.removeAll(keepingCapacity: true); skippingLine = false
            }
            if !skippingLine {
                if pending.count + fragment.element.count <= maxLineBytes { pending.append(contentsOf: fragment.element) }
                else { pending.removeAll(keepingCapacity: true); skippingLine = true }
            }
        }
    }
    private mutating func consume(_ line: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let name = string(event["name"]), let payload = event["structuredPayload"] as? [String: Any] else { return }
        if name == "actionStarted" { action += 1; snapshot.buildSucceeded = false; return }
        if name == "actionFinished", let tail = payload["tail"] as? [String: Any],
           let result = tail["buildResult"] as? [String: Any], string(result["status"]) == "succeeded" {
            snapshot.buildSucceeded = true; snapshot.operation = "Build complete"; return
        }
        guard let index = string(payload["sectionIndex"]) else { return }
        let key = "\(action):\(index)"
        if name == "logSectionCreated", let head = payload["head"] as? [String: Any],
           let type = head["_type"] as? [String: Any], type["_name"] as? String == "ActivityLogCommandInvocationSectionHead",
           let title = string(head["title"]), seen.insert(key).inserted {
            active[key] = String(title.prefix(240)); snapshot.operation = String(title.prefix(240))
        } else if name == "logSectionClosed", seen.contains(key), finished.insert(key).inserted {
            active[key] = nil; snapshot.completed += 1
            if let current = active.keys.sorted().last.flatMap({ active[$0] }) { snapshot.operation = current }
        }
        snapshot.active = active.count
    }
    private func string(_ object: Any?) -> String? { (object as? [String: Any])?["_value"] as? String }
}

actor CodeBuildEventReader {
    private let handle: FileHandle
    private var parser = CodeBuildEventParser()
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forReadingFrom: url)
    }
    deinit { try? handle.close() }
    func read() -> CodeBuildEventSnapshot? {
        let previous = parser.snapshot
        // A bounded chunk per tick avoids blocking job status/cancellation on logs.
        if let data = try? handle.read(upToCount: 1024 * 1024), !data.isEmpty { parser.append(data) }
        return parser.snapshot != previous ? parser.snapshot : nil
    }
    func drain() -> CodeBuildEventSnapshot {
        while let data = try? handle.read(upToCount: 1024 * 1024), !data.isEmpty { parser.append(data) }
        return parser.snapshot
    }
}
