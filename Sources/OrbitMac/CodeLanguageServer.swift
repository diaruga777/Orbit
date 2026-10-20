import Foundation
import Darwin
import OrbitCore

/// One SourceKit-LSP process per selected Xcode scheme. Unsaved buffers are
/// sent using didOpen/didChange and never written to the project's source files.
final class CodeLanguageServer: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var versions: [String: Int] = [:]
    private var buffers: [String: String] = [:]
    private var lastCompletion: (uri: String, start: CodePosition, context: String)?
    private var published: [String: [CodeDiagnostic]] = [:]
    private var ended = false
    private var stderr: FileHandle?

    init(project: CodeProject, derivedData: URL, logs: URL) throws {
        let config = URL(fileURLWithPath: project.root).appendingPathComponent("buildServer.json")
        let existing = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if existing == nil || existing?["lunaCodeManaged"] as? Bool == true {
            let packaged = Bundle.main.resourceURL?.appendingPathComponent("Orbit_OrbitMac.bundle/BuildServer")
            let resources = packaged.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                ?? Bundle.module.url(forResource: "BuildServer", withExtension: nil)
            guard let server = resources?.appendingPathComponent("xcode-build-server") else {
                throw CodeFailure("The bundled Xcode build server is missing.")
            }
            let workspace = project.path.hasSuffix(".xcodeproj") ? project.path + "/project.xcworkspace" : project.path
            let settings: [String: Any] = ["name": "Orbit Xcode", "version": "1.0", "bspVersion": "2.2.0",
                "languages": ["swift", "c", "cpp", "objective-c", "objective-cpp"],
                "argv": ["/usr/bin/python3", server.path], "kind": "xcode", "workspace": workspace,
                "scheme": project.scheme, "build_root": derivedData.path, "lunaCodeManaged": true]
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: config, options: .atomic)
        }
        let errorLog = logs.appendingPathComponent("sourcekit-" + UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        stderr = try FileHandle(forWritingTo: errorLog)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["sourcekit-lsp", "--default-workspace-type", "buildServer"]
        process.currentDirectoryURL = URL(fileURLWithPath: project.root)
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = stderr
        process.terminationHandler = { [weak self] _ in self?.finish(CodeFailure("SourceKit stopped. Reopen the project to reconnect.")) }
        try process.run()
        let handle = output.fileHandleForReading
        DispatchQueue(label: "Orbit.SourceKit.read").async { [weak self] in
            var buffer = Data()
            do {
                while true {
                    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                    if count == 0 { break }
                    if count < 0 { if errno == EINTR { continue }; throw CodeFailure("Cannot read SourceKit output.") }
                    buffer.append(contentsOf: bytes.prefix(count))
                    while let separator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        let header = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
                        guard let line = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                              let length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)), length >= 0, length <= 16 * 1024 * 1024 else {
                            throw CodeFailure("Invalid language server message.")
                        }
                        let start = separator.upperBound
                        guard buffer.count >= start + length else { break }
                        let message = buffer.subdata(in: start..<(start + length))
                        buffer.removeSubrange(..<(start + length))
                        if let json = try JSONSerialization.jsonObject(with: message) as? [String: Any] { self?.receive(json) }
                    }
                }
                self?.finish(CodeFailure("SourceKit disconnected."))
            } catch { self?.finish(error) }
        }
    }
    deinit { if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close(); try? stderr?.close() }
    func initialize(project: CodeProject) async throws {
        _ = try await request("initialize", ["processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": URL(fileURLWithPath: project.root).absoluteString,
            "capabilities": ["textDocument": ["completion": ["completionItem": ["snippetSupport": false]], "diagnostic": [:]]],
            "workspaceFolders": [["uri": URL(fileURLWithPath: project.root).absoluteString, "name": (project.root as NSString).lastPathComponent]]])
        try notify("initialized", [:])
    }
    func update(path: String, text: String, version: Int) throws {
        let uri = URL(fileURLWithPath: path).absoluteString
        let previous = lock.withCriticalScope { () -> (Int?, String?) in
            let old = versions[uri]; let buffer = buffers[uri]
            if old == nil || version > old! { versions[uri] = version; buffers[uri] = text }
            return (old, buffer)
        }
        if let old = previous.0, version <= old { return }
        if previous.1 == text { return }
        if previous.0 == nil {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            let language = ["m": "objective-c", "mm": "objective-cpp", "h": "c", "cpp": "cpp", "c": "c"][ext] ?? "swift"
            try notify("textDocument/didOpen", ["textDocument": ["uri": uri, "languageId": language, "version": version, "text": text]])
        } else {
            try notify("textDocument/didChange", ["textDocument": ["uri": uri, "version": version], "contentChanges": [["text": text]]])
        }
    }

    func diagnostics(path: String) async throws -> [CodeDiagnostic] {
        let uri = URL(fileURLWithPath: path).absoluteString
        do {
            let response = try await request("textDocument/diagnostic", ["textDocument": ["uri": uri]])
            return Self.diagnostics((response as? [String: Any])?["items"] as? [[String: Any]] ?? [])
        } catch {
            if let cached = lock.withCriticalScope({ published[uri] }) { return cached }
            throw error
        }
    }
    func complete(path: String, position: CodePosition) async throws -> [CodeCompletion] {
        let uri = URL(fileURLWithPath: path).absoluteString
        let text = lock.withCriticalScope { buffers[uri] ?? "" }
        let source = text as NSString
        let offset = min((position.offset(in: text) ?? source.length), source.length)
        var start = offset
        while start > 0, let scalar = UnicodeScalar(source.character(at: start - 1)),
              CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(scalar) { start -= 1 }
        let tokenPosition = CodePosition.at(utf16Offset: start, in: text)
        let context = source.substring(to: start) + "\u{0}" + source.substring(from: offset)
        // Swift 6.2 reuses completion sessions by URI/position/compile flags,
        // even after didChange/didClose changes the receiver's type. Move the
        // session once when surrounding code changes at the same token start.
        // Ordinary typing in the filter retains the fast existing session.
        if let last = lastCompletion, last.uri == uri, last.start == tokenPosition, last.context != context {
            let alternate = start == 0 ? CodePosition.at(utf16Offset: source.length, in: text) : CodePosition(line: 0, character: 0)
            _ = try await request("textDocument/completion", ["textDocument": ["uri": uri],
                "position": ["line": alternate.line, "character": alternate.character]])
        }
        lastCompletion = (uri, tokenPosition, context)
        let response = try await request("textDocument/completion", ["textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character], "context": ["triggerKind": 1]])
        let items = response as? [[String: Any]] ?? (response as? [String: Any])?["items"] as? [[String: Any]] ?? []
        let ranked = items.sorted { ($0["sortText"] as? String ?? $0["label"] as? String ?? "") < ($1["sortText"] as? String ?? $1["label"] as? String ?? "") }
        return ranked.prefix(512).compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let edit = item["textEdit"] as? [String: Any]
            let range = edit?["range"] as? [String: Any] ?? edit?["replace"] as? [String: Any]
            func position(_ key: String) -> CodePosition? {
                guard let value = range?[key] as? [String: Int], let line = value["line"], let char = value["character"] else { return nil }
                return CodePosition(line: line, character: char)
            }
            var text = edit?["newText"] as? String ?? item["insertText"] as? String ?? label
            // Xcode toolchains may emit placeholders even without snippet support.
            text = text.replacingOccurrences(of: #"\$\{\d+:([^}]*)\}"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\$\d+|\$\{\d+\}"#, with: "", options: .regularExpression)
            return CodeCompletion(label: label, detail: item["detail"] as? String ?? "", text: text, start: position("start"), end: position("end"))
        }
    }
    private static func diagnostics(_ items: [[String: Any]]) -> [CodeDiagnostic] {
        items.compactMap { item in
            guard let message = item["message"] as? String,
                let range = item["range"] as? [String: Any], let start = range["start"] as? [String: Int] else { return nil }
            return CodeDiagnostic(line: start["line"] ?? 0, character: start["character"] ?? 0, message: message, severity: item["severity"] as? Int ?? 1)
        }
    }
    private func request(_ method: String, _ params: [String: Any]) async throws -> Any {
        let id = lock.withCriticalScope { let id = nextID; nextID += 1; return id }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if ended { lock.unlock(); continuation.resume(throwing: CodeFailure("SourceKit is offline.")); return }
            pending[id] = continuation; lock.unlock()
            do { try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) }
            catch { resolve(id, .failure(error)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in self?.resolve(id, .failure(CodeFailure("SourceKit is still preparing the project. Build once, then try again."))) }
        }
    }
    private func notify(_ method: String, _ params: [String: Any]) throws { try write(["jsonrpc": "2.0", "method": method, "params": params]) }
    private func write(_ json: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: json)
        let frame = Data("Content-Length: \(bytes.count)\r\n\r\n".utf8) + bytes
        try writeLock.withCriticalScope { try input.fileHandleForWriting.write(contentsOf: frame) }
    }
    private func receive(_ json: [String: Any]) {
        if let id = json["id"] as? Int, json["method"] == nil {
            if let error = json["error"] as? [String: Any] { resolve(id, .failure(CodeFailure(error["message"] as? String ?? "SourceKit error"))) }
            else { resolve(id, .success(json["result"] ?? NSNull())) }
        } else if let id = json["id"] {
            let result: Any = (json["method"] as? String == "workspace/configuration") ? [] : NSNull()
            try? write(["jsonrpc": "2.0", "id": id, "result": result])
        } else if json["method"] as? String == "textDocument/publishDiagnostics",
                  let params = json["params"] as? [String: Any], let uri = params["uri"] as? String {
            let diagnostics = Self.diagnostics(params["diagnostics"] as? [[String: Any]] ?? [])
            lock.withCriticalScope { published[uri] = diagnostics }
        }
    }
    private func resolve(_ id: Int, _ result: Result<Any, Error>) { lock.withCriticalScope { pending.removeValue(forKey: id) }?.resume(with: result) }
    private func finish(_ error: Error) {
        let all = lock.withCriticalScope { () -> [CheckedContinuation<Any, Error>] in ended = true; defer { pending.removeAll() }; return Array(pending.values) }
        for continuation in all { continuation.resume(throwing: error) }
    }
}
