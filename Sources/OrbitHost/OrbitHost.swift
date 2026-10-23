import Foundation
import OrbitCore
import OrbitWidgets
import OrbitMac
import OrbitWire
import OrbitTransport

public actor OrbitHost {
    private let stateLock: OrbitStateLock
    public let root: URL
    public private(set) var service: CodeService
    private var targets: [OrbitTarget]
    private var iconLookups: [String: Date] = [:]
    public private(set) var configuration: OrbitConfiguration
    public private(set) var pairingUntil = Date.distantPast
    public init(root: URL = OrbitPaths.root) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        stateLock = try OrbitStateLock(root: root)
        let configURL = root.appendingPathComponent("config.json"), targetsURL = root.appendingPathComponent("targets.json")
        configuration = FileManager.default.fileExists(atPath: configURL.path) ? try JSONDecoder().decode(OrbitConfiguration.self, from: Data(contentsOf: configURL)) : OrbitConfiguration()
        targets = FileManager.default.fileExists(atPath: targetsURL.path) ? try JSONDecoder().decode([OrbitTarget].self, from: Data(contentsOf: targetsURL)) : []
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        service = try CodeService(root: root.appendingPathComponent("Builds"),
            installBundleID: configuration.phoneBundleID ?? Bundle.main.object(forInfoDictionaryKey: "OrbitPhoneBundleIdentifier") as? String,
            installHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/orbit-apple-adapter"))
    }
    public func openPairing() { pairingUntil = Date().addingTimeInterval(300) }
    public func isTrusted(_ peer: String) -> Bool { configuration.trustedPeers.contains(peer) }
    public func trust(_ peer: String) throws {
        guard Date() < pairingUntil else { throw CodeFailure("Open pairing on your Mac first.") }
        if !configuration.trustedPeers.contains(peer) { configuration.trustedPeers.append(peer); try saveConfiguration() }
    }
    private func saveConfiguration() throws { try JSONEncoder().encode(configuration).write(to: root.appendingPathComponent("config.json"), options: .atomic) }
    private func saveTargets() throws { try JSONEncoder().encode(targets).write(to: root.appendingPathComponent("targets.json"), options: .atomic) }
    public func handle(_ data: Data, peer: String? = nil) async -> Data {
        do {
            guard data.count <= CodeWire.maxPayloadBytes,
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = request["method"] as? String else { throw CodeFailure("Invalid Orbit request.") }
            let p = request["params"] as? [String: Any] ?? [:]
            if let peer, !isTrusted(peer) { throw CodeFailure("Approve this phone in Orbit Mac.") }
            let result = try await dispatch(method, p, peer: peer)
            return try JSONSerialization.data(withJSONObject: ["result": result], options: [.sortedKeys, .fragmentsAllowed])
        } catch { return (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])) ?? Data() }
    }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed) }
    private func required(_ p: [String: Any], _ key: String) throws -> String {
        guard let value = p[key] as? String, !value.isEmpty else { throw CodeFailure("Provide \(key).") }; return value
    }
    private func dispatch(_ method: String, _ p: [String: Any], peer: String?) async throws -> Any {
        switch method {
        case "status": return ["product": "Orbit", "targets": targets.count, "configuration": try object(configuration)]
        case "code":
            let data = try JSONSerialization.data(withJSONObject: p)
            let response = await service.handle(data, authenticatedPeerID: peer ?? "local-mac")
            return try JSONSerialization.jsonObject(with: response)
        case "browse": return try browse(p)
        case "targets":
            await populateMissingTargetIcons { project in
                var request = CodeRequest(.apps, path: project.path); request.project = project
                return try await self.decoded(request).apps ?? []
            }
            return try object(targets)
        case "applet_prompt": return ["prompt": OrbitAppletPrompt.text, "blank": OrbitAppletExport.blank]
        case "applets": return try appletDeployments()
        case "applet_add":
            guard peer == nil else { throw CodeFailure("Deploy applet files from the Mac.") }
            let source = try appletSource(p)
            let script = try OrbitAppletDefinition.widgetScript(source)
            let directory = root.appendingPathComponent("Applets")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let existing = try appletDeployments()
            guard existing.count < 24 || existing.contains(where: { $0["id"] == script.id }) else { throw CodeFailure("Remove an applet before adding another.") }
            try Data(source.utf8).write(to: directory.appendingPathComponent(script.id + ".js"), options: .atomic)
            return ["id": script.id, "name": script.definition.name, "pendingPhoneApproval": true]
        case "applet_remove":
            guard peer == nil else { throw CodeFailure("Remove Mac applet deployments on the Mac.") }
            let id = try required(p, "id")
            guard try appletDeployments().contains(where: { $0["id"] == id }) else { throw CodeFailure("Applet not found.") }
            try FileManager.default.removeItem(at: root.appendingPathComponent("Applets/" + id + ".js")); return ["removed": id]
        case "applet_export":
            guard peer == nil else { throw CodeFailure("Create standalone app projects on the Mac.") }
            let destination = try required(p, "destination")
            guard destination.hasPrefix("/") else { throw CodeFailure("Choose an absolute destination path.") }
            return try await OrbitAppletExport.create(source: p["path"] == nil ? nil : appletSource(p),
                destination: URL(fileURLWithPath: destination), bundleID: required(p, "bundleID"),
                icon: (p["iconPath"] as? String).map { URL(fileURLWithPath: $0) })
        case "widgets": return try widgetDeployments()
        case "widget_add":
            guard peer == nil else { throw CodeFailure("Deploy widget files from the Mac.") }
            let path = try required(p, "path")
            guard path.hasPrefix("/"), (try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= OrbitWidgetDefinition.maximumSourceBytes else { throw CodeFailure("Choose a JavaScript file under 128 KB.") }
            let script = try OrbitWidgetScript(source: String(contentsOfFile: path, encoding: .utf8))
            let directory = root.appendingPathComponent("Widgets"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let existing = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard existing.count < 24 || existing.contains(where: { $0.lastPathComponent == script.id + ".js" }) else { throw CodeFailure("Remove a widget before adding another.") }
            try Data(script.source.utf8).write(to: directory.appendingPathComponent(script.id + ".js"), options: .atomic)
            return ["id": script.id, "name": script.definition.name, "pendingPhoneApproval": true]
        case "widget_remove":
            guard peer == nil else { throw CodeFailure("Remove Mac widget deployments on the Mac.") }
            let id = try required(p, "id")
            guard try widgetDeployments().contains(where: { $0["id"] == id }) else { throw CodeFailure("Widget not found.") }
            try FileManager.default.removeItem(at: root.appendingPathComponent("Widgets/" + id + ".js")); return ["removed": id]
        case "setup_phone":
            guard peer == nil, targets.allSatisfy({ $0.jobID == nil && $0.pendingRequest == nil }) else { throw CodeFailure("Finish active builds before changing phone setup.") }
            let prefix = try required(p, "bundlePrefix")
            guard OrbitSetupState.validPrefix(prefix) else { throw CodeFailure("Choose a reverse-DNS bundle prefix.") }
            let bundleID = prefix + ".ios"
            if let existing = configuration.phoneBundleID, existing != bundleID { throw CodeFailure("Keep Orbit’s existing bundle prefix to preserve phone data.") }
            if configuration.phoneBundleID == bundleID { return ["bundleID": bundleID] }
            configuration.phoneBundleID = bundleID; try saveConfiguration()
            service = try CodeService(root: root.appendingPathComponent("Builds"), installBundleID: bundleID, installHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/orbit-apple-adapter"))
            return ["bundleID": bundleID]
        case "phone_setup_status":
            if let peer {
                let allowed = ["cache", "account", "certificate", "pairing", "connection"]
                guard p.keys.allSatisfy(allowed.contains), allowed.allSatisfy({ p[$0] is Bool }) else { throw CodeFailure("Invalid phone readiness.") }
                let value: [String: Any] = ["peer": peer, "updatedAt": Date().timeIntervalSince1970, "readiness": p]
                try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent("phone-setup.json"), options: .atomic)
                return ["received": true]
            }
            return (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("phone-setup.json")))) ?? NSNull()
        case "artifact": return try object(await service.refreshBuild(jobID: required(p, "jobID"), offset: p["offset"] as? Int ?? 0))
        case "devices":
            let result = await service.handle(try JSONEncoder().encode(CodeRequest(.devices)))
            let response = try JSONDecoder().decode(CodeResponse.self, from: result)
            if let error = response.error { throw CodeFailure(error) }
            return try object(response.devices ?? [])
        case "target_add": return try await add(p)
        case "target_remove":
            let id = try required(p, "id")
            guard let target = targets.first(where: { $0.id == id }), target.jobID == nil else { throw CodeFailure("Wait for the target’s current build before removing it.") }
            targets.removeAll { $0.id == id }; try saveTargets(); return ["removed": id]
        case "schedule":
            let index = try index(p)
            let hours = p["intervalHours"] as? Int ?? targets[index].intervalHours
            guard (1...8760).contains(hours) else { throw CodeFailure("Choose an interval from 1 to 8760 hours.") }
            if targets[index].project.minimumProfileHours != nil {
                guard hours <= 144 else { throw CodeFailure("Personal Team refreshes must run at least every six days. Use account=paid when adding a target with paid membership.") }
                targets[index].project.minimumProfileHours = hours + 12
            }
            targets[index].intervalHours = hours; targets[index].enabled = p["enabled"] as? Bool ?? true
            try saveTargets(); return try object(targets[index])
        case "build":
            let index = try index(p)
            return try await start(index, launch: p["launch"] as? Bool ?? false)
        case "job": return try await job(required(p, "id"))
        case "cancel":
            let id = try required(p, "id")
            let retained = targets.contains { ($0.jobID == id || $0.lastJobID == id) && $0.jobKind == "retained" }
            var request = CodeRequest(retained ? .overnightCancel : .cancel); request.jobID = id
            return try JSONSerialization.jsonObject(with: await service.handle(JSONEncoder().encode(request)))
        case "repo_search": return try await OrbitGitHub.search(try required(p, "query"))
        case "repo_inspect": return try await OrbitGitHub.inspect(try required(p, "repository"))
        case "repo_add": return try await importRepository(p)
        case "configure":
            // Network routes are local preferences. A paired phone can select
            // them too, but changing trust or filesystem roots stays on the Mac.
            let provider = p["provider"] as? String ?? configuration.provider
            guard ["local", "tailscale", "syncthing", "dumbpipe"].contains(provider) else { throw CodeFailure("Unknown pipe provider.") }
            if provider == "syncthing" {
                guard let relay = p["relay"] as? String, URL(string: relay)?.scheme == "relay" else { throw CodeFailure("Provide an explicit relay:// address.") }
                configuration.relay = relay
            }
            if provider == "tailscale" {
                guard let address = p["address"] as? String, OrbitPeerAddress(syncthingURL: address) != nil else { throw CodeFailure("Provide a tcp:// address for this pipe.") }
                configuration.address = address
            }
            configuration.provider = provider; try saveConfiguration()
            return ["configuration": try object(configuration), "restartRequired": true]
        case "pairing_open":
            guard peer == nil else { throw CodeFailure("Open pairing from the Mac.") }; openPairing(); return ["seconds": 300]
        case "forget":
            guard peer == nil else { throw CodeFailure("Remove phone access from the Mac.") }
            configuration.trustedPeers.removeAll(); pairingUntil = .distantPast
            try await service.revokeEndpointAuthorizations(); try saveConfiguration(); return ["forgotten": true]
        default: throw CodeFailure("Unknown Orbit method: \(method)")
        }
    }
    private func appletSource(_ p: [String: Any]) throws -> String {
        let path = try required(p, "path")
        guard path.hasPrefix("/"), (try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= OrbitWidgetDefinition.maximumSourceBytes else { throw CodeFailure("Choose a JavaScript file under 128 KB.") }
        let source = try String(contentsOfFile: path, encoding: .utf8)
        _ = try OrbitAppletDefinition.parse(source)
        return source
    }
    private func appletDeployments() throws -> [[String: String]] {
        let directory = root.appendingPathComponent("Applets")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "js" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(24).map {
                let source = try appletSource(["path": $0.path]), definition = try OrbitAppletDefinition.parse(source)
                return ["id": definition.id, "name": definition.name, "source": source, "digest": OrbitWidgetDefinition.digest(source)]
            }
    }
    private func widgetDeployments() throws -> [[String: String]] {
        let directory = root.appendingPathComponent("Widgets")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "js" }.prefix(24).map {
            let source = try String(contentsOf: $0, encoding: .utf8), definition = try OrbitWidgetDefinition.parse(source)
            return ["id": definition.id, "name": definition.name, "source": source, "digest": OrbitWidgetDefinition.digest(source)]
        }
    }
    private func index(_ p: [String: Any]) throws -> Int {
        let id = try required(p, "id")
        guard let i = targets.firstIndex(where: { $0.id == id }) else { throw CodeFailure("Target not found.") }; return i
    }
    private func add(_ p: [String: Any]) async throws -> Any {
        guard p["trust"] as? Bool == true else { throw CodeFailure("Review this source, then add with trust=true. Xcode builds can execute repository scripts on your Mac.") }
        let path = try required(p, "project"), scheme = try required(p, "scheme"), device = try required(p, "deviceID")
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard path.hasPrefix("/"), ["xcodeproj", "xcworkspace"].contains(url.pathExtension), FileManager.default.fileExists(atPath: url.path) else { throw CodeFailure("Choose an existing Xcode project or workspace.") }
        var project = CodeProject(path: url.path, scheme: scheme)
        if let prefix = p["bundlePrefix"] as? String {
            guard OrbitSetupState.validPrefix(prefix) else { throw CodeFailure("Invalid bundle prefix.") }; project.bundlePrefix = prefix
        }
        if let team = p["teamID"] as? String, !team.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { project.developmentTeam = team }
        var request = CodeRequest(.apps, path: url.path); request.project = project
        let response = try JSONDecoder().decode(CodeResponse.self, from: await service.handle(JSONEncoder().encode(request)))
        if let error = response.error { throw CodeFailure(error) }
        guard let app = response.apps?.first(where: { $0.project.scheme == scheme }) else { throw CodeFailure("This scheme has no runnable iOS application. Choose a shared app scheme.") }
        if let index = targets.firstIndex(where: { $0.project.path == url.path && $0.project.scheme == scheme && $0.deviceID == device }) {
            if let icon = app.iconPNG { targets[index].iconPNG = icon; try saveTargets() }
            return try object(targets[index])
        }
        let hours = p["intervalHours"] as? Int ?? 144
        guard (1...8760).contains(hours) else { throw CodeFailure("Choose an interval from 1 to 8760 hours.") }
        let account = p["account"] as? String ?? "free"
        guard ["free", "paid"].contains(account) else { throw CodeFailure("Choose free or paid for account.") }
        if account == "free" {
            guard hours <= 144 else { throw CodeFailure("Use an interval of at most 144 hours for a free Personal Team.") }
            project.minimumProfileHours = hours + 12
        }
        var target = OrbitTarget(name: p["name"] as? String ?? app.name, project: project, deviceID: device,
            branch: p["branch"] as? String ?? "main", intervalHours: hours, enabled: p["enabled"] as? Bool ?? false)
        target.iconPNG = app.iconPNG
        target.repository = p["repository"] as? String
        targets.append(target); try saveTargets(); return try object(target)
    }
    /// Backfill catalogs from before icons were retained. Failed/missing icons
    /// never hide targets or invoke a build, and polling does not hammer Xcode.
    func populateMissingTargetIcons(discover: (CodeProject) async throws -> [CodeBuildApp]) async {
        var changed = false
        for target in targets where target.iconPNG == nil {
            let key = target.project.path + "\u{0}" + target.project.scheme
            guard Date().timeIntervalSince(iconLookups[key] ?? .distantPast) >= 300 else { continue }
            iconLookups[key] = Date()
            guard let apps = try? await discover(target.project),
                  let icon = apps.first(where: { $0.project.path == target.project.path && $0.project.scheme == target.project.scheme })?.iconPNG else { continue }
            // Discovery suspends this actor; a target may have been removed meanwhile.
            for index in targets.indices where targets[index].project.path == target.project.path && targets[index].project.scheme == target.project.scheme {
                targets[index].iconPNG = icon
                changed = true
            }
        }
        if changed { try? saveTargets() }
    }
    private func decoded(_ request: CodeRequest) async throws -> CodeResponse {
        let response = try JSONDecoder().decode(CodeResponse.self, from: await service.handle(JSONEncoder().encode(request)))
        if let error = response.error { throw CodeFailure(error) }; return response
    }
    private func job(_ id: String) async throws -> Any {
        if let target = targets.first(where: { $0.jobID == id || $0.lastJobID == id }), target.jobKind == "retained" {
            let response = try await decoded(CodeRequest(.overnightStatus))
            guard let job = response.overnightJobs?.first(where: { $0.id == id }) else { throw CodeFailure("Build job not found.") }
            var value = try object(job) as? [String: Any] ?? [:]
            if let compilation = job.compilationJobID {
                var poll = CodeRequest(.job); poll.jobID = compilation
                value["log"] = try await decoded(poll).job?.log ?? ""
            }
            return value
        }
        var poll = CodeRequest(.job); poll.jobID = id
        return try object(await decoded(poll).job)
    }
    private func start(_ index: Int, launch: Bool = false) async throws -> Any {
        let target = targets[index], id = target.id
        if let jobID = target.jobID { return try await job(jobID) }
        var branch = target.branch
        if target.repository != nil {
            _ = try await OrbitCommand.run("/usr/bin/git", ["check-ref-format", "--branch", branch])
            _ = try await OrbitCommand.run("/usr/bin/git", ["fetch", "--no-tags", "origin", "refs/heads/" + branch + ":refs/remotes/origin/" + branch], directory: URL(fileURLWithPath: target.project.root))
            branch = "refs/remotes/origin/" + branch
        }
        var request: CodeRequest
        if let pending = target.pendingRequest { request = pending }
        else if launch {
            request = CodeRequest(.runOnDevice); request.project = target.project
            request.deviceBuild = CodeDeviceBuild(branch: branch, deviceID: target.deviceID)
        } else {
            request = CodeRequest(.overnightSubmit)
            let identity = CodeOvernightTarget(peerID: "orbit-mac", deviceID: target.deviceID, project: target.project, branch: branch, generation: id)
            request.overnight = CodeOvernightSubmission(invocationID: request.id, target: identity, localDay: ISO8601DateFormatter().string(from: Date()))
        }
        guard let i = targets.firstIndex(where: { $0.id == id }) else { throw CodeFailure("Target was removed.") }
        targets[i].lastAttempt = Date(); targets[i].pendingRequest = request; try saveTargets()
        let response = try await decoded(request)
        let jobID: String
        let value: Any
        if let job = response.overnightJobs?.first { jobID = job.id; value = try object(job) }
        else if let job = response.job { jobID = job.id; value = try object(job) }
        else { throw CodeFailure("The Mac did not accept the build.") }
        guard let current = targets.firstIndex(where: { $0.id == id }) else { throw CodeFailure("Target was removed.") }
        targets[current].pendingRequest = nil; targets[current].jobID = jobID; targets[current].lastJobID = jobID
        targets[current].jobKind = request.operation == .overnightSubmit ? "retained" : "build"
        targets[current].failure = nil; try saveTargets(); return value
    }
    public func tick(at date: Date = Date()) async {
        for id in targets.map(\.id) {
            guard let i = targets.firstIndex(where: { $0.id == id }) else { continue }
            if let jobID = targets[i].jobID {
                do {
                    let retained = targets[i].jobKind == "retained"
                    let value = try await job(jobID) as? [String: Any] ?? [:]
                    let state = value["state"] as? String ?? ""
                    guard let j = targets.firstIndex(where: { $0.id == id }), targets[j].jobID == jobID else { continue }
                    if ["succeeded", "failed", "cancelled"].contains(state) {
                        targets[j].jobID = nil
                        if state == "succeeded" { targets[j].lastSuccess = date; targets[j].failure = nil }
                        else { targets[j].failure = value["failureMessage"] as? String ?? (value["error"] as? [String: Any])?["recovery"] as? String ?? "The build did not finish. Check its job log." }
                    } else if retained && ["waitingForPhone", "unknownCompletion"].contains(state) {
                        var retry = CodeRequest(.overnightInstall); retry.jobID = jobID
                        _ = try await decoded(retry)
                    }
                } catch { if let j = targets.firstIndex(where: { $0.id == id }) { targets[j].failure = error.localizedDescription } }
            } else if targets[i].isDue(at: date) {
                do { _ = try await start(i) }
                catch { if let j = targets.firstIndex(where: { $0.id == id }) { targets[j].failure = error.localizedDescription; targets[j].lastAttempt = date } }
            }
        }
        try? saveTargets()
    }
    private func browse(_ p: [String: Any]) throws -> Any {
        let path = p["path"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/") else { throw CodeFailure("Choose an absolute Mac path.") }
        let entries = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: p["hidden"] as? Bool == true ? [] : [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let offset = max(0, p["offset"] as? Int ?? 0)
        return ["items": try entries.dropFirst(offset).prefix(100).map { url in
            ["path": url.path, "name": url.lastPathComponent, "directory": try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false] as [String: Any]
        }, "next": offset + 100 < entries.count ? offset + 100 as Any : NSNull()]
    }
    private func importRepository(_ p: [String: Any]) async throws -> Any {
        guard p["trust"] as? Bool == true else { throw CodeFailure("Review this repository, then add with trust=true.") }
        let name = try OrbitGitHub.repository(required(p, "repository"))
        let inspection = try await OrbitGitHub.inspect(name)
        guard inspection["compatible"] as? Bool == true else { throw CodeFailure("No Xcode project was found in this repository.") }
        let folder = root.appendingPathComponent("Repositories/" + name.replacingOccurrences(of: "/", with: "--"))
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw CodeFailure("This repository is already cloned. Add a local target from \(folder.path).") }
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let branch = p["branch"] as? String ?? inspection["defaultBranch"] as? String ?? "main"
        _ = try await OrbitCommand.run("/usr/bin/git", ["clone", "--single-branch", "--branch", branch, "--", "https://github.com/" + name + ".git", folder.path])
        var input = p
        let projects = inspection["projects"] as? [String] ?? []
        let selected = p["project"] as? String ?? (projects.count == 1 ? projects[0] : "")
        guard !selected.isEmpty, projects.contains(selected) else { throw CodeFailure("Repository cloned at \(folder.path). Choose one of its projects: \(projects.joined(separator: ", "))") }
        input["project"] = folder.appendingPathComponent(selected).path; input["branch"] = branch
        return try await add(input)
    }
}
