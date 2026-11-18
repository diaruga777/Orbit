import SwiftUI
import AppKit
import OrbitCore

struct OrbitAddAppView: View {
    @ObservedObject var model: OrbitMacModel
    @ObservedObject var setup: OrbitSetupModel
    @State private var advanced = false
    @State private var filter = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Add an app").font(.largeTitle.bold())
                Picker("Build for", selection: $model.addPlatform) {
                    Text("iPhone").tag("iOS")
                    Text("This Mac").tag("macOS")
                }.pickerStyle(.segmented).frame(maxWidth: 320)
                    .onChange(of: model.addPlatform) { _, platform in model.project = ""; model.scheme = ""; model.addError = ""; model.scheduled = platform == "iOS" }
                Picker("Source", selection: Binding(get: { model.addSource }, set: { model.changeSource($0) })) {
                    Text("On This Mac").tag("local")
                    Text("GitHub").tag("github")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).disabled(model.downloading || model.inspectingRepository)

                if model.addSource == "local" { localProjects } else { githubProjects }
                if model.addPlatform == "macOS" {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Project or Package.swift path", text: $model.project)
                        TextField("Xcode scheme or executable product", text: $model.scheme)
                        Text("Builds and opens on this Mac. Existing apps keep their location and signing identity.").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    if !model.project.isEmpty { appSelection }
                    phoneSelection
                }
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.schemeVariants.count > 1 {
                            Picker("Build scheme", selection: $model.scheme) {
                                ForEach(model.schemeVariants, id: \.project.scheme) { Text($0.project.scheme).tag($0.project.scheme) }
                            }
                        }
                        TextField("Branch", text: $model.branch)
                        Picker("Signing account", selection: $model.team) {
                            Text("Use project settings").tag("")
                            ForEach(setup.teams) { Text($0.name).tag($0.id) }
                            if !model.team.isEmpty && !setup.teams.contains(where: { $0.id == model.team }) {
                                Text("Setup account").tag(model.team)
                            }
                        }
                        if model.addPlatform == "macOS" {
                            TextField("Install path (automatic)", text: $model.macInstallPath)
                            TextField("Bundle ID (use existing app or project)", text: $model.macBundleID)
                            TextField("Signing identity (use existing certificate)", text: $model.macSigningIdentity)
                            TextField("Info.plist path (new Swift package apps)", text: $model.macInfoPlist)
                            Picker("Configuration", selection: $model.macConfiguration) {
                                Text("Debug").tag("Debug"); Text("Release").tag("Release")
                            }
                        } else { Toggle("Free Personal Team", isOn: $model.personal) }
                        Toggle("Refresh automatically", isOn: $model.scheduled)
                        if model.scheduled {
                            TextField("Hours between refreshes", text: $model.hours)
                            if model.addPlatform == "iOS" { Text("Free accounts refresh every 6 days or sooner.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.top, 12)
                }
                if !model.addError.isEmpty {
                    Label(model.addError, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Button(action: { model.add() }) {
                        Text(model.adding ? "Adding app…" : "Add App").frame(minWidth: 100)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canAdd)
                    if model.adding { ProgressView().controlSize(.small) }
                    else { Text(model.scheduled ? "Refreshes every \(model.hours == "144" ? "6 days" : model.hours + " hours")." : "Manual builds").font(.callout).foregroundStyle(.secondary) }
                }
                if model.adding { Text("Checking the project with Xcode…").font(.callout).foregroundStyle(.secondary) }
            }.padding(32).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
                .disabled(model.adding)
        }
        .task {
            if model.team.isEmpty { model.team = setup.state.teamID }
            if model.addPlatform == "iOS" { await model.loadPhones(preferred: setup.state.deviceID) }
        }
    }

    private var localProjects: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your projects").font(.headline)
                Spacer()
                if model.detecting { ProgressView().controlSize(.small) }
                Button { Task { await model.detectProjects() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Look for projects again").disabled(model.detecting)
                Button("Choose Project…", action: model.chooseProject)
            }
            if !model.detectedProjects.isEmpty {
                TextField("Filter projects", text: $filter).textFieldStyle(.roundedBorder)
            }
            if model.detectedProjects.isEmpty {
                Text(model.detecting ? "Looking for projects…" : "No projects found in your projects folder.")
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                let matches = model.detectedProjects.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if matches.isEmpty {
                            Text("No matching projects").foregroundStyle(.secondary).padding()
                        }
                        ForEach(matches, id: \.self) { path in
                            projectRow(path)
                        }
                    }
                }.frame(height: 190).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
            if model.detecting && !model.detectedProjects.isEmpty {
                Text("Updating saved previews…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func projectRow(_ path: String) -> some View {
        Button { model.inspectProject(path) } label: {
            HStack(spacing: 12) {
                OrbitAppThumbnail(data: model.previews[path]?.first?.iconPNG, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent).font(.body.weight(.medium))
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if model.project == path { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(model.project == path ? Color.accentColor.opacity(0.1) : .clear)
        }.buttonStyle(.plain)
    }
    private var appSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App").font(.headline)
            if model.readingSchemes { ProgressView("Reading app details…").controlSize(.small) }
            if !model.selectedApps.isEmpty {
                HStack(spacing: 14) {
                    OrbitAppThumbnail(data: model.selectedApp?.iconPNG, size: 52)
                    Picker("App to add", selection: Binding(get: { model.selectedChoice }, set: { model.scheme = $0 })) {
                        ForEach(model.appChoices, id: \.project.scheme) { app in
                            Label {
                                Text(app.name)
                            } icon: {
                                if let data = app.iconPNG, let image = NSImage(data: data) { Image(nsImage: image).resizable().frame(width: 20, height: 20) }
                                else { Image(systemName: "app") }
                            }.tag(app.project.scheme)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !model.readingSchemes {
                Text("No iPhone apps found in the project preview.").foregroundStyle(.secondary)
                Button("Check with Xcode…", action: model.inspectWithXcode)
            }
        }
    }
    private var phoneSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Install on").font(.headline)
                Spacer()
                if model.loadingPhones { ProgressView().controlSize(.small) }
                Button("Check Again") { Task { await model.loadPhones(preferred: setup.state.deviceID) } }.disabled(model.loadingPhones)
            }
            Picker("Phone", selection: $model.phone) {
                Text("Choose a phone").tag("")
                ForEach(model.phones, id: \.id) { phone in Label(phone.name, systemImage: "iphone").tag(phone.id) }
                if !model.phone.isEmpty && !model.phones.contains(where: { $0.id == model.phone }) {
                    Text("Recent phone · offline").tag(model.phone)
                }
            }.labelsHidden()
            if model.phones.isEmpty && !model.loadingPhones {
                Text("Connect your iPhone and unlock it to find it here.").font(.callout).foregroundStyle(.secondary)
            }
            if !model.phoneError.isEmpty { Text(model.phoneError).font(.callout).foregroundStyle(.red) }
        }
    }
    private var githubProjects: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Find a GitHub repository", text: $model.query).textFieldStyle(.roundedBorder).onSubmit(model.search)
                Button("Search", action: model.search).disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty || model.searching)
                if model.searching || model.inspectingRepository { ProgressView().controlSize(.small) }
            }
            ForEach(Array(model.results.enumerated()), id: \.offset) { _, result in
                Button { model.inspect(result["repository"] as? String ?? "") } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result["repository"] as? String ?? "Repository").font(.headline)
                        if let description = result["description"] as? String { Text(description).foregroundStyle(.secondary).lineLimit(2) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.buttonStyle(.plain).disabled(model.inspectingRepository || model.downloading)
            }
            if let info = model.inspection {
                Divider()
                Text(info["repository"] as? String ?? "Repository").font(.headline)
                if info["compatible"] as? Bool == true {
                    if model.repositoryProjects.isEmpty {
                        Button("Download Project", action: model.downloadRepository).disabled(model.downloading)
                        if model.downloading { ProgressView("Downloading project…").controlSize(.small) }
                        Text("Download to preview the apps before adding one.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.repositoryProjects, id: \.self) { projectRow($0) }
                    }
                } else { Text("No Xcode project found. Try another repository.").foregroundStyle(.secondary) }
            }
        }
    }
}

struct OrbitAppThumbnail: View {
    let data: Data?
    var size: CGFloat = 44
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary).padding(8) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22)).accessibilityHidden(true)
    }
}
