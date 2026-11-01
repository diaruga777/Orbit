import Foundation
import OrbitCore
import OrbitWidgets
import OrbitMac
import OrbitWire
import OrbitTransport

public actor OrbitHost {
    private var applyConnections: (@Sendable (OrbitConfiguration) async throws -> [String])?
    private var connectionCodes: [String] = []
    private var connectionError: String?
    private var configuringConnections = false
    private var syncedPeers: Set<String> = []
    public func installConnectionHandler(_ handler: @escaping @Sendable (OrbitConfiguration) async throws -> [String]) async {
        applyConnections = handler
        do { connectionCodes = try await handler(configuration); connectionError = nil }
        catch { connectionError = error.localizedDescription }
    }
    public func canonicalPeer(_ peer: String) -> String {
        configuration.peerAliases?[peer] ?? peer
    }
    private var startingMacUpdate = false
    private let macTargets: OrbitMacTargets
    private let macUpdate: OrbitMacUpdate
    private let stateLock: OrbitStateLock
    public let root: URL
    private let appDiagnostics: OrbitAppDiagnosticCollector
    private let diagnostics: OrbitDiagnostics
    public private(set) var service: CodeService
    private let scripts = OrbitScriptLibrary()
    private var targets: [OrbitTarget]
    private var updatingIcons = false
    private var startingTargets: Set<String> = []
    private var diagnosticStores: [String: OrbitDiagnostics] = [:]
    private var jobStates: [String: String] = [:]
    private var iconLookups: [String: Date] = [:]
    public private(set) var configuration: OrbitConfiguration
    public private(set) var pairingUntil = Date.distantPast
    public init(root: URL = OrbitPaths.root) throws {
        self.root = root
        macTargets = OrbitMacTargets(root: root)
        macUpdate = OrbitMacUpdate(root: root)
        appDiagnostics = try OrbitAppDiagnosticCollector(root: root.appendingPathComponent("Logs/Apps"))
        diagnostics = OrbitDiagnostics.store(directory: root.appendingPathComponent("Logs"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        stateLock = try OrbitStateLock(root: root)
        let configURL = root.appendingPathComponent("config.json"), targetsURL = root.appendingPathComponent("targets.json")
        configuration = FileManager.default.fileExists(atPath: configURL.path) ? try JSONDecoder().decode(OrbitConfiguration.self, from: Data(contentsOf: configURL)) : OrbitConfiguration()
        targets = FileManager.default.fileExists(atPath: targetsURL.path) ? try JSONDecoder().decode([OrbitTarget].self, from: Data(contentsOf: targetsURL)) : []
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if !configuration.allowedRoots.isEmpty || configuration.appletFolder != nil || configuration.widgetFolder != nil {
            let base = configuration.allowedRoots.first.map { URL(fileURLWithPath: $0) } ?? root
            let folders: [OrbitJavaScriptFile.Kind: URL] = [
                .applet: configuration.appletFolder.map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("Applets"),
                .widget: configuration.widgetFolder.map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("Widgets")]
            let marker = root.appendingPathComponent("script-folders-migrated")
            if !FileManager.default.fileExists(atPath: marker.path) {
                do {
                    try scripts.migrate(from: [.applet: root.appendingPathComponent("Applets"), .widget: root.appendingPathComponent("Widgets")], to: folders)
                    try Data().write(to: marker, options: .atomic)
                } catch { /* Folder access failures appear in script_status; builds remain available. */ }
            }
        }
        service = try CodeService(root: root.appendingPathComponent("Builds"),
            installBundleID: configuration.phoneBundleID ?? Bundle.main.object(forInfoDictionaryKey: "OrbitPhoneBundleIdentifier") as? String,
            installHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/orbit-apple-adapter"), diagnostics: diagnostics)
    }
    public func collectAppDiagnostics() async {
        guard let apps = try? await service.installedApps() else { return }
        await appDiagnostics.collect(apps)
    }
    public func openPairing() { pairingUntil = Date().addingTimeInterval(300) }
    public func isTrusted(_ peer: String) -> Bool { configuration.trustedPeers.contains(canonicalPeer(peer)) }
    public func trust(_ peer: String) throws {
        guard Date() < pairingUntil else { throw CodeFailure("Open pairing on your Mac first.") }
        if !configuration.trustedPeers.contains(peer) { configuration.trustedPeers.append(peer); try saveConfiguration() }
    }
    private func saveConfiguration() throws { try JSONEncoder().encode(configuration).write(to: root.appendingPathComponent("config.json"), options: .atomic) }
    private func saveTargets() throws { try JSONEncoder().encode(targets).write(to: root.appendingPathComponent("targets.json"), options: .atomic) }
    public func handle(_ data: Data, peer: String? = nil) async -> Data {
        let started = Date()
        var fields = ["origin": peer ?? "mac", "request": UUID().uuidString]
        var upload = false
        do {
            guard data.count <= CodeWire.maxPayloadBytes,
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = request["method"] as? String else { throw CodeFailure("Invalid Orbit request.") }
            let p = request["params"] as? [String: Any] ?? [:]
            upload = method == "diagnostics_upload"
            if let trace = request["trace"] as? String, UUID(uuidString: trace) != nil { fields["request"] = trace }
            fields["method"] = method
            if let operation = p["operation"] as? String { fields["operation"] = operation }
            if let id = p["id"] as? String { fields["actionID"] = id }
            if !upload { diagnostics.record("rpc", "received", fields) }
            if let peer, !isTrusted(peer) { throw CodeFailure("Approve this phone in Orbit Mac.") }
            let result = try await dispatch(method, p, peer: peer.map { canonicalPeer($0) })
            let response = try JSONSerialization.data(withJSONObject: ["result": result], options: [.sortedKeys, .fragmentsAllowed])
            fields["milliseconds"] = String(Int(Date().timeIntervalSince(started) * 1000)); fields["bytes"] = String(response.count)
            if !upload { diagnostics.record("rpc", "completed", fields) }
            return response
        } catch {
            diagnostics.error("rpc", "failed", error, fields)
            return (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])) ?? Data()
        }
    }
    private func phoneDiagnostics(_ peer: String) throws -> OrbitDiagnostics {
        // Validate before using a remotely supplied identity as a path component.
        let peer = try DeviceID(string: peer).description
        if let store = diagnosticStores[peer] { return store }
        let store = OrbitDiagnostics(directory: root.appendingPathComponent("Logs/Phones").appendingPathComponent(peer))
        diagnosticStores[peer] = store
        return store
    }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed) }
    private func required(_ p: [String: Any], _ key: String) throws -> String {
        guard let value = p[key] as? String, !value.isEmpty else { throw CodeFailure("Provide \(key).") }; return value
    }
    private func dispatch(_ method: String, _ p: [String: Any], peer: String?) async throws -> Any {
        switch method {
        case "app_debug_setup":
            guard peer == nil else { throw CodeFailure("Set up app debugging on your Mac.") }
            return ["files": try OrbitAppletExport.diagnosticSources(),
                    "containerPath": "Library/Application Support/OrbitAppDiagnostics"] as [String: Any]
        case "diagnostics_upload":
            guard let peer else { throw CodeFailure("Use a paired phone to upload logs.") }
            let data = try JSONSerialization.data(withJSONObject: p["events"] ?? [])
            guard data.count <= 128 * 1024 else { throw CodeFailure("Diagnostic batch too large.") }
            let events = try JSONDecoder().decode([OrbitDiagnosticEvent].self, from: data)
            guard events.count <= 128 else { throw CodeFailure("Too many diagnostic events.") }
            try phoneDiagnostics(peer).append(events)
            return ["acknowledged": events.last?.id ?? ""]
        case "diagnostics":
            guard peer == nil else { throw CodeFailure("Read diagnostics on your Mac.") }
            let limit = p["limit"] as? Int ?? 100
            if let app = p["app"] as? String {
                guard p["phone"] == nil else { throw CodeFailure("Choose app or phone diagnostics.") }
                return ["events": try object(await appDiagnostics.events(app: app, maximum: limit))]
            }
            if let phone = p["phone"] as? String {
                guard configuration.trustedPeers.contains(phone) else { throw CodeFailure("Phone not found.") }
                return ["events": try object(phoneDiagnostics(phone).recent(maximum: limit))]
            }
            return ["directory": root.appendingPathComponent("Logs").path,
                    "apps": try object(await appDiagnostics.list()),
                    "phones": configuration.trustedPeers,
                    "events": try object(diagnostics.recent(maximum: limit))]
        case "mac_update_status":
            let value = await macUpdate.status()
            if !startingMacUpdate, !(await macUpdate.isActive()) { await service.endMacUpdate() }
            return value
        case "mac_update_prepare":
            guard peer == nil else { throw CodeFailure("Start the update from Orbit’s Mac section.") }
            try await service.beginMacUpdate()
            return ["ready": true]
        case "mac_update":
            let active = await macUpdate.isActive()
            if startingMacUpdate || active { return await macUpdate.status() }
            startingMacUpdate = true
            defer { startingMacUpdate = false }
            try await service.beginMacUpdate()
            do { return try await macUpdate.start() }
            catch { await service.endMacUpdate(); throw error }
        case "status": return ["product": "Orbit", "targets": targets.count, "configuration": try object(configuration)]
        case "code":
            let data = try JSONSerialization.data(withJSONObject: p)
            let response = await service.handle(data, authenticatedPeerID: peer ?? "local-mac")
            return try JSONSerialization.jsonObject(with: response)
        case "installed_apps": return try object(await service.installedApps(deviceID: p["deviceID"] as? String))
        case "projects_detect":
            let roots = configuration.allowedRoots.map { URL(fileURLWithPath: $0) } + [FileManager.default.homeDirectoryForCurrentUser]
            return await Task.detached { OrbitProjectDiscovery.scan(roots: roots) }.value
        case "project_preview":
            let path = try required(p, "project")
            guard path.hasPrefix("/"), ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: path).pathExtension) else { throw CodeFailure("Choose an Xcode project or workspace.") }
            let apps = await Task.detached { CodeProjectPreview.apps(path: path) }.value
            return try object(apps)
        case "project_apps":
            guard p["trust"] as? Bool == true else { throw CodeFailure("Only inspect source you trust. Xcode can run project code on your Mac.") }
            let path = try required(p, "project")
            guard path.hasPrefix("/"), ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: path).pathExtension) else { throw CodeFailure("Choose an Xcode project or workspace.") }
            return try object(await decoded(CodeRequest(.apps, path: path)).apps ?? [])
        case "browse": return try browse(p)
        case "targets":
            if !updatingIcons {
                updatingIcons = true
                Task {
                    await populateMissingTargetIcons { project in
                        var request = CodeRequest(.apps, path: project.path); request.project = project
                        return try await self.decoded(request).apps ?? []
                    }
                    updatingIcons = false
                }
            }
            return try object(targets)
        case "applet_prompt": return ["prompt": OrbitAppletPrompt.text, "blank": OrbitAppletExport.blank]
        case "applets": return scriptDeployments(.applet)
        case "script_import", "applet_add", "widget_add":
            guard peer == nil else { throw CodeFailure("Import JavaScript files on the Mac.") }
            let path = try required(p, "path")
            guard path.hasPrefix("/") else { throw CodeFailure("Choose an absolute file path.") }
            let file = try OrbitJavaScriptFile(url: URL(fileURLWithPath: path))
            if method == "applet_add", file.kind != .applet { throw CodeFailure("Choose JavaScript with an Orbit applet header.") }
            if method == "widget_add", file.kind != .widget { throw CodeFailure("Choose JavaScript with an Orbit widget header.") }
            return try scripts.add(file, folders: scriptFolders)
        case "applet_remove", "widget_remove":
            guard peer == nil else { throw CodeFailure("Remove Mac scripts on the Mac.") }
            let id = try required(p, "id")
            try scripts.remove(id, kind: method == "applet_remove" ? .applet : .widget, folders: scriptFolders)
            return ["removed": id]
        case "script_status":
            guard peer == nil else { throw CodeFailure("Choose folders on the Mac.") }
            scanScripts()
            return ["appletFolder": scriptFolders[.applet]!.path, "widgetFolder": scriptFolders[.widget]!.path, "issues": scripts.issues]
        case "script_folder":
            guard peer == nil else { throw CodeFailure("Choose folders on the Mac.") }
            guard let kind = OrbitJavaScriptFile.Kind(rawValue: try required(p, "kind")) else { throw CodeFailure("Choose applet or widget.") }
            let path = try required(p, "path")
            guard path.hasPrefix("/") else { throw CodeFailure("Choose an absolute folder path.") }
            let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else { throw CodeFailure("Choose an existing folder.") }
            let old = scriptFolders
            var new = old; new[kind] = folder
            try scripts.migrate(from: old, to: new)
            if kind == .applet { configuration.appletFolder = folder.path } else { configuration.widgetFolder = folder.path }
            try saveConfiguration()
            try Data().write(to: root.appendingPathComponent("script-folders-migrated"), options: .atomic)
            return ["folder": folder.path]
        case "applet_export":
            guard peer == nil else { throw CodeFailure("Create standalone app projects on the Mac.") }
            let destination = try required(p, "destination")
            guard destination.hasPrefix("/") else { throw CodeFailure("Choose an absolute destination path.") }
            return try await OrbitAppletExport.create(source: p["path"] == nil ? nil : appletSource(p),
                destination: URL(fileURLWithPath: destination), bundleID: required(p, "bundleID"),
                icon: (p["iconPath"] as? String).map { URL(fileURLWithPath: $0) })
        case "widgets": return scriptDeployments(.widget)
        case "setup_folder":
            guard peer == nil else { throw CodeFailure("Choose folders on the Mac.") }
            let path = try required(p, "path")
            guard path.hasPrefix("/") else { throw CodeFailure("Choose an absolute folder path.") }
            let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw CodeFailure("Choose an existing folder.") }
            let old = scriptFolders
            var new = old
            if configuration.appletFolder == nil { new[.applet] = folder.appendingPathComponent("Applets") }
            if configuration.widgetFolder == nil { new[.widget] = folder.appendingPathComponent("Widgets") }
            try scripts.migrate(from: old, to: new)
            configuration.allowedRoots = [folder.path]; try saveConfiguration()
            try Data().write(to: root.appendingPathComponent("script-folders-migrated"), options: .atomic)
            return ["folder": folder.path]
        case "setup_phone":
            guard peer == nil, targets.allSatisfy({ $0.jobID == nil && $0.pendingRequest == nil }) else { throw CodeFailure("Finish active builds before changing phone setup.") }
            let prefix = try required(p, "bundlePrefix")
            guard OrbitSetupState.validPrefix(prefix) else { throw CodeFailure("Choose a reverse-DNS bundle prefix.") }
            let bundleID = prefix + ".ios"
            if let existing = configuration.phoneBundleID, existing != bundleID { throw CodeFailure("Keep Orbit’s existing bundle prefix to preserve phone data.") }
            if configuration.phoneBundleID == bundleID { return ["bundleID": bundleID] }
            configuration.phoneBundleID = bundleID; try saveConfiguration()
            service = try CodeService(root: root.appendingPathComponent("Builds"), installBundleID: bundleID, installHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/orbit-apple-adapter"), diagnostics: diagnostics)
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
            return try await start(index, launch: p["launch"] as? Bool, monitorBundleID: p["monitorBundleID"] as? String)
        case "job": return try await job(required(p, "id"))
        case "cancel":
            let id = try required(p, "id")
            if targets.contains(where: { ($0.jobID == id || $0.lastJobID == id) && $0.jobKind == "mac" }) {
                return try await macTargets.job(id, cancel: true)
            }
            let retained = targets.contains { ($0.jobID == id || $0.lastJobID == id) && $0.jobKind == "retained" }
            var request = CodeRequest(retained ? .overnightCancel : .cancel); request.jobID = id
            return try JSONSerialization.jsonObject(with: await service.handle(JSONEncoder().encode(request)))
        case "repo_search": return try await OrbitGitHub.search(try required(p, "query"))
        case "repo_inspect": return try await OrbitGitHub.inspect(try required(p, "repository"))
        case "repo_prepare": return try await prepareRepository(p)
        case "repo_add": return try await importRepository(p)
        case "connection_status":
            return ["provider": configuration.provider, "ready": !connectionCodes.isEmpty && connectionError == nil,
                    "error": connectionError ?? "", "phones": configuration.trustedPeers.count,
                    "syncedPhones": syncedPeers.count]
        case "connection_routes":
            guard let peer else { throw CodeFailure("Use a paired phone to sync connections.") }
            guard !configuringConnections else { throw CodeFailure("Connection setup is still finishing. Try again shortly.") }
            if let alias = p["transportPeerID"] as? String {
                let alias = try DeviceID(string: alias).description
                guard alias == peer || (!configuration.trustedPeers.contains(alias) && (configuration.peerAliases?[alias] == nil || configuration.peerAliases?[alias] == peer)) else {
                    throw CodeFailure("That connection belongs to another paired phone.")
                }
                if alias != peer, configuration.peerAliases?[alias] != peer {
                    var aliases = configuration.peerAliases ?? [:]
                    guard aliases.filter({ $0.value == peer }).count < 4 || aliases[alias] != nil else { throw CodeFailure("Too many phone transport identities.") }
                    aliases[alias] = peer
                    let previous = configuration.peerAliases
                    configuration.peerAliases = aliases
                    do { try saveConfiguration() } catch { configuration.peerAliases = previous; throw error }
                }
            }
            if p["receivedCodes"] as? [String] == connectionCodes { syncedPeers.insert(peer) }
            return try object(OrbitConnectionRoutes(provider: configuration.provider, pairingCodes: connectionCodes, accountPeerID: peer))
        case "configure":
            guard !configuringConnections else { throw CodeFailure("Connection setup is already running.") }
            var next = configuration
            next.provider = p["provider"] as? String ?? next.provider
            try next.validateConnection()
            if next.provider == "syncthing" { next.relay = p["relay"] as? String ?? next.relay }
            if next.provider == "tailscale" { next.address = p["address"] as? String ?? next.address }
            try next.validateConnection(requireAddress: true)
            guard let applyConnections else { throw CodeFailure("Connections are still starting. Try again shortly.") }
            configuringConnections = true
            defer { configuringConnections = false }
            let previous = configuration
            let codes = try await applyConnections(next)
            // An actor can receive phone syncs while the listener starts. Preserve trust changes.
            configuration.provider = next.provider; configuration.address = next.address; configuration.relay = next.relay
            do { try saveConfiguration() }
            catch {
                configuration.provider = previous.provider; configuration.address = previous.address; configuration.relay = previous.relay
                _ = try? await applyConnections(previous)
                throw error
            }
            if codes != connectionCodes { syncedPeers.removeAll() }
            connectionCodes = codes; connectionError = nil
            return ["configuration": try object(configuration), "restartRequired": false]
        case "pairing_open":
            guard peer == nil else { throw CodeFailure("Open pairing from the Mac.") }; openPairing(); return ["seconds": 300]
        case "forget":
            guard peer == nil else { throw CodeFailure("Remove phone access from the Mac.") }
            configuration.trustedPeers.removeAll(); configuration.peerAliases = nil; syncedPeers.removeAll(); pairingUntil = .distantPast
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
    private var scriptFolders: [OrbitJavaScriptFile.Kind: URL] {
        let base = configuration.allowedRoots.first.map { URL(fileURLWithPath: $0) } ?? root
        return [.applet: configuration.appletFolder.map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("Applets"),
                .widget: configuration.widgetFolder.map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("Widgets")]
    }
    public func scanScripts() { scripts.scan(scriptFolders) }
    private func scriptDeployments(_ kind: OrbitJavaScriptFile.Kind) -> [[String: String]] {
        scanScripts()
        return scripts.list(kind)
    }
    private func index(_ p: [String: Any]) throws -> Int {
        let id = try required(p, "id")
        guard let i = targets.firstIndex(where: { $0.id == id }) else { throw CodeFailure("Target not found.") }; return i
    }
    private func add(_ p: [String: Any]) async throws -> Any {
        guard p["trust"] as? Bool == true else { throw CodeFailure("Review this source, then add with trust=true. Xcode builds can execute repository scripts on your Mac.") }
        if p["platform"] as? String == "macOS" { return try await addMac(p) }
        guard p["platform"] == nil || p["platform"] as? String == "iOS" else { throw CodeFailure("Choose iOS or macOS.") }
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
    private func addMac(_ p: [String: Any]) async throws -> Any {
        let deployment = try await macTargets.inspect(p)
        let settings = try JSONSerialization.jsonObject(with: deployment.settings) as? [String: Any] ?? [:]
        guard let path = settings["project"] as? String, let scheme = settings["scheme"] as? String,
              let branch = settings["branch"] as? String else { throw CodeFailure("Couldn’t read this Mac project.") }
        if let existing = targets.first(where: { $0.mac?.installPath == deployment.installPath }) {
            guard existing.project.path == path, existing.project.scheme == scheme else { throw CodeFailure("Another target already owns this installation path.") }
            return try object(existing)
        }
        let hours = p["intervalHours"] as? Int ?? 144
        guard (1...8760).contains(hours) else { throw CodeFailure("Choose an interval from 1 to 8760 hours.") }
        var target = OrbitTarget(name: p["name"] as? String ?? URL(fileURLWithPath: deployment.installPath).deletingPathExtension().lastPathComponent,
            project: CodeProject(path: path, scheme: scheme), deviceID: "host-mac", branch: branch,
            intervalHours: hours, enabled: p["enabled"] as? Bool ?? false)
        target.mac = deployment
        target.repository = p["repository"] as? String
        targets.append(target); try saveTargets()
        return try object(target)
    }
    /// Backfill catalogs from before icons were retained. Failed/missing icons
    /// never hide targets or invoke a build, and polling does not hammer Xcode.
    func populateMissingTargetIcons(discover: (CodeProject) async throws -> [CodeBuildApp]) async {
        var changed = false
        for target in targets where target.iconPNG == nil && target.mac == nil {
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
        if targets.contains(where: { ($0.jobID == id || $0.lastJobID == id) && $0.jobKind == "mac" }) {
            return try await macTargets.job(id)
        }
        if let target = targets.first(where: { $0.jobID == id || $0.lastJobID == id }), target.jobKind == "retained" {
            let response = try await decoded(CodeRequest(.overnightStatus))
            guard let job = response.overnightJobs?.first(where: { $0.id == id }) else { throw CodeFailure("Build job not found.") }
            var value = try object(job) as? [String: Any] ?? [:]
            if let compilation = job.compilationJobID {
                var poll = CodeRequest(.job); poll.jobID = compilation
                let compilation = try await decoded(poll).job
                value["log"] = compilation?.log ?? ""
                value["compilation"] = try object(compilation)
            }
            return value
        }
        var poll = CodeRequest(.job); poll.jobID = id
        return try object(await decoded(poll).job)
    }
    private func start(_ index: Int, launch: Bool? = nil, monitorBundleID: String? = nil) async throws -> Any {
        let target = targets[index], id = target.id
        if let jobID = target.jobID { return try await job(jobID) }
        guard startingTargets.insert(id).inserted else { throw CodeFailure("This build is already starting. Check Apps in a moment.") }
        defer { startingTargets.remove(id) }
        diagnostics.record("build", "starting", ["target": id, "launch": String(launch ?? (target.mac != nil))])
        var branch = target.branch
        if target.repository != nil {
            _ = try await OrbitCommand.run("/usr/bin/git", ["check-ref-format", "--branch", branch])
            _ = try await OrbitCommand.run("/usr/bin/git", ["fetch", "--no-tags", "origin", "refs/heads/" + branch + ":refs/remotes/origin/" + branch], directory: URL(fileURLWithPath: target.project.root))
            branch = "refs/remotes/origin/" + branch
        }
        if target.mac != nil {
            guard let current = targets.firstIndex(where: { $0.id == id }) else { throw CodeFailure("Target was removed.") }
            targets[current].jobID = UUID().uuidString; targets[current].lastJobID = targets[current].jobID
            targets[current].jobKind = "mac"; targets[current].lastAttempt = Date(); targets[current].failure = nil
            try saveTargets()
            do { return try await macTargets.start(targets[current], branch: branch, launch: launch ?? true) }
            catch {
                if let current = targets.firstIndex(where: { $0.id == id }) {
                    targets[current].jobID = nil; targets[current].failure = error.localizedDescription; try? saveTargets()
                }
                throw error
            }
        }
        var request: CodeRequest
        if let pending = target.pendingRequest { request = pending }
        else if launch == true {
            request = CodeRequest(.runOnDevice); request.project = target.project
            request.deviceBuild = CodeDeviceBuild(branch: branch, deviceID: target.deviceID, monitorBundleID: monitorBundleID)
        } else {
            request = CodeRequest(.overnightSubmit)
            let identity = CodeOvernightTarget(peerID: "orbit-mac", deviceID: target.deviceID, project: target.project, branch: branch, generation: id)
            request.overnight = CodeOvernightSubmission(invocationID: request.id, target: identity, localDay: ISO8601DateFormatter().string(from: Date()))
            request.overnight?.monitorBundleID = monitorBundleID
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
        targets[current].failure = nil; try saveTargets()
        diagnostics.record("build", "accepted", ["target": id, "job": jobID])
        return value
    }
    public func tick(at date: Date = Date()) async {
        let active = await macUpdate.isActive()
        if startingMacUpdate || active { return }
        await service.endMacUpdate()
        for id in targets.map(\.id) {
            guard let i = targets.firstIndex(where: { $0.id == id }) else { continue }
            if let jobID = targets[i].jobID {
                do {
                    let retained = targets[i].jobKind == "retained"
                    let value = try await job(jobID) as? [String: Any] ?? [:]
                    let state = value["state"] as? String ?? ""
                    if jobStates[jobID] != state {
                        jobStates[jobID] = state
                        diagnostics.record("build", "state", ["job": jobID, "state": state])
                    }
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
        let path = p["path"] as? String ?? configuration.allowedRoots.first ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/") else { throw CodeFailure("Choose an absolute Mac path.") }
        let entries = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: p["hidden"] as? Bool == true ? [] : [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let offset = max(0, p["offset"] as? Int ?? 0)
        return ["items": try entries.dropFirst(offset).prefix(100).map { url in
            ["path": url.path, "name": url.lastPathComponent, "directory": try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false] as [String: Any]
        }, "next": offset + 100 < entries.count ? offset + 100 as Any : NSNull()]
    }
    private func prepareRepository(_ p: [String: Any]) async throws -> [String: Any] {
        guard p["trust"] as? Bool == true else { throw CodeFailure("Review this repository, then download with trust=true.") }
        let name = try OrbitGitHub.repository(required(p, "repository"))
        let inspection = try await OrbitGitHub.inspect(name)
        guard inspection["compatible"] as? Bool == true else { throw CodeFailure("No Xcode project was found in this repository.") }
        let projectsRoot = configuration.allowedRoots.first.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Repositories")
        let folder = projectsRoot.appendingPathComponent(name.replacingOccurrences(of: "/", with: "--"))
        let branch = p["branch"] as? String ?? inspection["defaultBranch"] as? String ?? "main"
        if FileManager.default.fileExists(atPath: folder.path) {
            let remote = try await OrbitCommand.run("/usr/bin/git", ["remote", "get-url", "origin"], directory: folder)
            guard String(decoding: remote, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "https://github.com/" + name + ".git" else {
                throw CodeFailure("Another project already uses this folder. Choose it from On This Mac instead.")
            }
        } else {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await OrbitCommand.run("/usr/bin/git", ["clone", "--single-branch", "--branch", branch, "--", "https://github.com/" + name + ".git", folder.path])
        }
        let projects = inspection["projects"] as? [String] ?? []
        let paths = projects.map { folder.appendingPathComponent($0).standardizedFileURL }.filter { $0.path.hasPrefix(folder.path + "/") }
        return ["repository": name, "branch": branch, "projects": paths.map(\.path)]
    }
    private func importRepository(_ p: [String: Any]) async throws -> Any {
        let prepared = try await prepareRepository(p)
        let projects = prepared["projects"] as? [String] ?? []
        let selected = p["project"] as? String ?? (projects.count == 1 ? projects[0] : "")
        guard let path = projects.first(where: { $0 == selected || $0.hasSuffix("/" + selected) }), !selected.isEmpty else {
            throw CodeFailure("Choose one of the downloaded Xcode projects.")
        }
        var input = p; input["project"] = path; input["branch"] = prepared["branch"]
        return try await add(input)
    }
}
