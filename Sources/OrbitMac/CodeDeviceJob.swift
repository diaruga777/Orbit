import Foundation
import OrbitCore

extension CodeJobs {
    func runOnDevice(_ request: CodeRequest, project: CodeProject, job: CodeJob, process: CodeProcess, log: URL) async throws {
        guard let options = request.deviceBuild else { throw CodeFailure("Choose a phone first.") }
        if options.installOnly != true {
            let phones = try await CodeDeviceSupport.devices(root: root)
            guard phones.contains(where: { $0.id == options.deviceID }) else { throw CodeFailure("The selected phone is not connected. Connect it to your Mac by cable or on the same network, unlock it, then try again.") }
        }
        stage(job.id, "Creating isolated checkout…", from: 0.10, to: 0.15, seconds: 15)
        let checkout = try await CodeDeviceCheckout.create(project: project, branch: options.branch, root: root,
            name: job.id, process: process)
        do {
            stage(job.id, "Checking destination and signing…", from: 0.15, to: 0.25, seconds: 45)
            let buildProject = checkout.project
            if options.installOnly != true {
                try await CodeDeviceSupport.validateDestination(buildProject, deviceID: options.deviceID, root: root, process: process)
            }
            // Install-only builds must not wait on a live Xcode destination if
            // the phone locks after submission. CoreDevice connects at install.
            let destination = options.installOnly == true ? "generic/platform=iOS" : "platform=iOS,id=" + options.deviceID
            let settings = try await CodeDeviceSupport.settings(buildProject, root: root, process: process, destination: destination)
            guard let app = try CodeDeviceSupport.primarySettings(settings, project: buildProject), CodeDeviceSupport.isApp(app),
                  let bundle = app["PRODUCT_BUNDLE_IDENTIFIER"], !bundle.lowercased().contains("webdriveragent"),
                  let product = app["FULL_PRODUCT_NAME"], product.hasSuffix(".app") else {
                throw CodeFailure("Choose a runnable iOS app scheme in the row menu.")
            }
            try CodeOrbitIdentity.verify(bundleID: bundle, project: buildProject,
                phoneBundleID: phoneBundleID, monitorBundleID: options.monitorBundleID)
            var localApp: [String: String]?
            if CodeDeviceSigning.team(app) == nil {
                // Git worktrees omit ignored local signing configuration. Resolve
                // only the team from the original project; source still builds
                // from the selected committed revision in the detached checkout.
                let localSettings = try await CodeDeviceSupport.settings(project, root: root, process: process, destination: destination)
                localApp = try CodeDeviceSupport.primarySettings(localSettings, project: project)
            }
            let signing = try CodeDeviceSigning.arguments(checkout: app, local: localApp)
            let refresh = try await CodeProfileRefresh.prepare(project: project, settings: app, device: options.deviceID, root: root, process: process)
            defer { refresh?.restore() }
            let derived = derivedData(project).appendingPathComponent("Device")
            let artifactBuildNumber = String(Int(Date().timeIntervalSince1970))
            let artifactFlags = options.artifactTarget == nil ? [] : ["CURRENT_PROJECT_VERSION=" + artifactBuildNumber]
            let products = derived.appendingPathComponent("Products")
            stage(job.id, "Compiling on your Mac…", from: 0.25, to: 0.80, seconds: 240)
            guard try await runBuildCommand(arguments: buildProject.xcodeArguments + ["-configuration", "Debug", "-destination", destination,
                "-derivedDataPath", derived.path, "-resultBundlePath", root.appendingPathComponent(job.id + ".xcresult").path,
                "-allowProvisioningUpdates", "CONFIGURATION_BUILD_DIR=" + products.path] + signing + artifactFlags + ["build"], directory: checkout.directory.path, process: process, log: log, id: job.id,
                from: 0.25, to: 0.80) == 0 else {
                throw CodeFailure(CodeBuildFailure.message(log: log))
            }
            recordCompilation(job.id, revision: checkout.revision)
            let appURL = products.appendingPathComponent(product)
            // Read the actual built product so scheme dependencies cannot change the install target.
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: appURL.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
            guard plist?["CFBundleIdentifier"] as? String == bundle else { throw CodeFailure("The built app does not match the selected scheme.") }
            try await CodeProfileRefresh.verify(app: appURL, minimumHours: project.minimumProfileHours, root: root, process: process)
            if let target = options.artifactTarget {
                guard plist?["CFBundleVersion"] as? String == artifactBuildNumber else { throw CodeFailure("The app’s Info.plist must use CURRENT_PROJECT_VERSION so overnight updates can be verified.") }
                let store = try CodeArtifactStore(root: root.appendingPathComponent("Artifacts"))
                let artifact = try await store.retain(app: appURL, jobID: job.id, target: target, commit: checkout.revision, process: process)
                try recordArtifact(job.id, artifact: artifact)
            } else {
            if options.requiresInstallHandoff(for: bundle) {
                try await waitForInstallHandoff(job.id)
            }
            let installLock = CodeDeviceInstallLock.shared
            let installToken = try await installLock.acquire(options.deviceID)
            defer { Task { await installLock.release(options.deviceID, token: installToken) } }
            stage(job.id, "Installing on your phone…", from: 0.80, to: 0.93, seconds: 40)
            do {
                try await command("/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--timeout", "120", "--device", options.deviceID, appURL.path], directory: checkout.directory.path, process: process, log: log)
            } catch {
                throw CodeFailure("The app built, but installation failed. Unlock your phone, check its connection to Xcode, then try again. See the Mac job log for details.")
            }
            let installer = CodeNativeInstaller(logs: root)
            guard let version = plist?["CFBundleShortVersionString"] as? String, let build = plist?["CFBundleVersion"] as? String,
                  try await installer.confirm(bundleID: bundle, version: version, build: build, deviceID: options.deviceID, process: process) else {
                throw CodeFailure("The installation hasn’t been confirmed on your phone. Check its connection before trying again.")
            }
            let installed = CodeInstalledApp(deviceID: options.deviceID, bundleID: bundle,
                name: plist?["CFBundleDisplayName"] as? String ?? plist?["CFBundleName"] as? String ?? project.scheme,
                version: version, build: build, installedAt: Date(),
                profileExpiresAt: try? await CodeProfileRefresh.expiration(app: appURL, root: root, process: process))
            try recordInstallation(job.id, app: installed)
            if options.installOnly != true {
                stage(job.id, "Launching on your phone…", from: 0.93, to: 0.97, seconds: 10)
                try await command("/usr/bin/xcrun", ["devicectl", "device", "process", "launch", "--device", options.deviceID, "--terminate-existing", bundle], directory: checkout.directory.path, process: process, log: log)
            }
            }
        } catch {
            await checkout.remove(root: root)
            throw error
        }
        stage(job.id, "Cleaning up checkout…", from: 0.97, to: 0.99, seconds: 10)
        await checkout.remove(root: root)
    }
    private func command(_ executable: String, _ arguments: [String], directory: String, process: CodeProcess, log: URL) async throws {
        guard try await process.run(executable, arguments, directory: directory, log: log, timeout: 180) == 0 else { throw CodeFailure("The device command failed. See the Mac job log for details.") }
    }
}

enum CodeDeviceSigning {
    static func team(_ settings: [String: String]) -> String? {
        let value = (settings["DEVELOPMENT_TEAM"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    static func arguments(checkout: [String: String], local: [String: String]?) throws -> [String] {
        // A team committed on the selected branch takes precedence over local
        // settings on the editor's branch.
        if team(checkout) != nil { return [] }
        guard let local, let team = team(local) else {
            throw CodeFailure("No development team is configured for this app. Set its Signing & Capabilities team in the original project on your Mac (or its local signing configuration), then retry the build.")
        }
        // Apply to the entire build so embedded extensions share the app's team.
        // Keep provisioning, certificates and entitlements under Xcode's control.
        return ["DEVELOPMENT_TEAM=" + team]
    }
}

/// A detached checkout protects the editor's branch, index and unsaved Mac files.
struct CodeDeviceCheckout {
    var directory: URL
    var revision: String
    var repository: String
    var project: CodeProject
    static func create(project: CodeProject, branch: String, root: URL, name: String, process: CodeProcess = CodeProcess()) async throws -> Self {
        let repository = try await CodeDeviceSupport.git(["rev-parse", "--show-toplevel"], directory: project.root, root: root, process: process)
        let source = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
        let repo = URL(fileURLWithPath: repository).resolvingSymlinksInPath().path
        guard source.hasPrefix(repo + "/"), !branch.isEmpty else { throw CodeFailure("The project must be inside a Git repository with a main branch.") }
        let revision = try await CodeDeviceSupport.git(["rev-parse", "--verify", "--end-of-options", branch + "^{commit}"], directory: repo, root: root, process: process)
        var selected = try CodeOrbitIdentity.resolve(project)
        let directory = root.appendingPathComponent("Checkout-" + name)
        do {
            _ = try await CodeDeviceSupport.git(["worktree", "add", "--detach", directory.path, revision], directory: repo, root: root, process: process)
        } catch {
            _ = try? await CodeDeviceSupport.git(["worktree", "remove", "--force", directory.path], directory: repo, root: root)
            throw error
        }
        selected.path = directory.appendingPathComponent(String(source.dropFirst(repo.count + 1))).path
        do {
            if let prefix = selected.bundlePrefix, let team = selected.developmentTeam, let bundle = selected.iosBundleID,
               FileManager.default.fileExists(atPath: directory.appendingPathComponent("Config/Orbit.xcconfig").path) {
                let local = directory.appendingPathComponent("Config/Local.xcconfig")
                try Data("ORBIT_BUNDLE_PREFIX = \(prefix)\nDEVELOPMENT_TEAM = \(team)\nORBIT_IOS_BUNDLE_IDENTIFIER = \(bundle)\n".utf8).write(to: local, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
                // Source checkouts keep generated native archives ignored; the
                // bundled wizard snapshot already commits its reviewed copies.
                for relative in ["Vendor/OrbitNet.xcframework", "Vendor/DeviceGateway/IDevice.xcframework", "Vendor/IrohDirect"] {
                    let destination = directory.appendingPathComponent(relative)
                    let native = URL(fileURLWithPath: project.root).appendingPathComponent(relative)
                    if !FileManager.default.fileExists(atPath: destination.path), FileManager.default.fileExists(atPath: native.path) {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: native, to: destination)
                    }
                }
            }
        } catch {
            _ = try? await CodeDeviceSupport.git(["worktree", "remove", "--force", directory.path], directory: repo, root: root)
            throw error
        }
        return Self(directory: directory, revision: revision, repository: repo, project: selected)
    }
    func remove(root: URL) async {
        _ = try? await CodeDeviceSupport.git(["worktree", "remove", "--force", directory.path], directory: repository, root: root)
    }
}
