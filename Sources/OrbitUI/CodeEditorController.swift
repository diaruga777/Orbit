#if os(iOS)
import UIKit
import Runestone
import TreeSitterSwiftRunestone
import TreeSitterJSONRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterCRunestone
import OrbitCore

@MainActor final class CodeEditorController: UIViewController, TextViewDelegate, UITableViewDataSource, UITableViewDelegate {
    private final class Document {
        var draft: CodeDraft
        let view: CodeTextView
        let peer: String
        var remote: CodeDocument?
        var diagnostics: [CodeDiagnostic] = []
        var generation = 0
        init(draft: CodeDraft, view: CodeTextView, peer: String) { self.draft = draft; self.view = view; self.peer = peer }
    }
    private struct Pair: CharacterPair { let leading: String; let trailing: String }
    private let environment: CodeEnvironment
    private var documents: [Document] = []
    private var active: Document?
    private let container = UIView()
    private let tabs = UIScrollView()
    private let tabStack = UIStackView()
    private var tabPresentation = ""
    private let status = UIButton(type: .system)
    private let positionLabel = UILabel()
    private let footer = UIStackView()
    private let buildProgress = UIProgressView(progressViewStyle: .default)
    private let buildStatus = UILabel()
    private let buildSummary = UIStackView()
    private let empty = UIContentUnavailableView(configuration: .empty())
    private var workspaceGeneration = 0
    private var openGeneration = 0
    private var startingJob = false
    private var loadingSchemes = false
    private let completionTable = UITableView()
    private var completions: [CodeCompletion] = []
    private var completionIndex = 0
    private var completionGeneration = 0
    private var completionPath = ""
    private var completionSelection = NSRange(location: 0, length: 0)
    private var analysis: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var poll: Timer?
    private var polling = false
    private var saving = false
    private var job: CodeJob?
    private var fontSize: CGFloat
    private var saveButton: UIBarButtonItem!
    private var buildButton: UIBarButtonItem!
    var openFiles: (() -> Void)?

    init(environment: CodeEnvironment) {
        self.environment = environment
        let size = environment.defaults.double(forKey: "Code.fontSize")
        fontSize = size > 0 ? size : 15
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { poll?.invalidate(); analysis?.cancel(); completionTask?.cancel(); draftTask?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        title = "Orbit"; navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "sidebar.left"), style: .plain, target: self, action: #selector(files))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Project Files"
        saveButton = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain, target: self, action: #selector(saveAction))
        saveButton.accessibilityLabel = "Save to Mac"; saveButton.isEnabled = false
        buildButton = UIBarButtonItem(image: UIImage(systemName: "hammer"), menu: buildMenu())
        buildButton.accessibilityLabel = "Build and Deploy"
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: editorMenu())
        more.accessibilityLabel = "Editor Actions"
        navigationItem.rightBarButtonItems = [more, buildButton, saveButton]
        tabStack.axis = .horizontal; tabStack.spacing = 4; tabStack.alignment = .fill
        tabs.addSubview(tabStack); tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabs.showsHorizontalScrollIndicator = false; tabs.backgroundColor = .secondarySystemBackground
        NSLayoutConstraint.activate([
            tabStack.topAnchor.constraint(equalTo: tabs.contentLayoutGuide.topAnchor), tabStack.bottomAnchor.constraint(equalTo: tabs.contentLayoutGuide.bottomAnchor),
            tabStack.leadingAnchor.constraint(equalTo: tabs.contentLayoutGuide.leadingAnchor, constant: 8), tabStack.trailingAnchor.constraint(equalTo: tabs.contentLayoutGuide.trailingAnchor, constant: -8),
            tabStack.heightAnchor.constraint(equalTo: tabs.frameLayoutGuide.heightAnchor)
        ])
        status.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        status.titleLabel?.adjustsFontForContentSizeCategory = true
        status.titleLabel?.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        positionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.contentHorizontalAlignment = .leading; status.setTitle("Ready", for: .normal)
        status.addTarget(self, action: #selector(showIssues), for: .touchUpInside)
        positionLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); positionLabel.textColor = .secondaryLabel
        footer.axis = .horizontal; footer.spacing = 12; footer.addArrangedSubview(status); footer.addArrangedSubview(positionLabel)
        footer.isLayoutMarginsRelativeArrangement = true; footer.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        footer.backgroundColor = .secondarySystemBackground
        footer.heightAnchor.constraint(greaterThanOrEqualTo: status.heightAnchor).isActive = true
        buildStatus.font = .preferredFont(forTextStyle: .caption1); buildStatus.numberOfLines = 0
        buildStatus.adjustsFontForContentSizeCategory = true
        buildStatus.accessibilityIdentifier = "CodeEditorBuildStatus"
        buildProgress.isAccessibilityElement = true; buildProgress.accessibilityLabel = "Build progress"
        buildProgress.accessibilityIdentifier = "CodeEditorBuildProgress"
        buildSummary.axis = .vertical; buildSummary.spacing = 6
        buildSummary.isLayoutMarginsRelativeArrangement = true
        buildSummary.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        buildSummary.addArrangedSubview(buildStatus); buildSummary.addArrangedSubview(buildProgress)
        buildSummary.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(buildChanged), name: CodeBuildMonitor.changed, object: environment.builds)
        let vertical = UIStackView(arrangedSubviews: [tabs, buildSummary, container, footer]); vertical.axis = .vertical
        vertical.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(vertical)
        NSLayoutConstraint.activate([
            vertical.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor), vertical.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            vertical.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), vertical.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 44), footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])
        empty.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: container.leadingAnchor), empty.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            empty.topAnchor.constraint(equalTo: container.topAnchor), empty.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        completionTable.dataSource = self; completionTable.delegate = self; completionTable.rowHeight = 40
        completionTable.layer.cornerRadius = 10; completionTable.layer.borderWidth = 0.5; completionTable.layer.borderColor = UIColor.separator.cgColor
        completionTable.backgroundColor = .secondarySystemBackground; completionTable.isHidden = true
        container.addSubview(completionTable)
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
        projectDidChange(); updateChrome(); foreground()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let low = view.bounds.height < 430
        tabs.isHidden = documents.count < 2 || (low && view.keyboardLayoutGuide.layoutFrame.height > 80)
        footer.isHidden = low && view.keyboardLayoutGuide.layoutFrame.height > 80
        placeCompletions()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        let range = active?.view.selectedRange
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.view.setNeedsLayout() }) { _ in
            if let range { self.active?.view.scrollRangeToVisible(range) }
        }
    }
    @objc private func buildChanged() {
        let monitor = environment.builds
        if monitor.job?.installHandoff != nil { persistAll() }
        if let value = monitor.job, value.id == job?.id { job = value; buildButton.menu = buildMenu() }
        buildSummary.isHidden = !monitor.isStarting && monitor.job?.state != .running
        buildStatus.text = "\(Int(monitor.fraction * 100))% estimated · \(monitor.stage)\n" + (monitor.job?.progressDetail.map { $0 + "\n" } ?? "") + monitor.backgroundMessage
        buildProgress.progress = Float(monitor.fraction)
        buildProgress.accessibilityValue = "\(Int(monitor.fraction * 100)) percent estimated"
    }
    @objc private func files() { openFiles?() }
    @objc private func background() { persistAll(); poll?.invalidate(); poll = nil; analysis?.cancel(); hideCompletions() }
    @objc private func foreground() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in await self?.refreshRemote() } }
        if let id = environment.defaults.string(forKey: "Code.job." + environment.peerID()) { Task { await refreshJob(id) } }
    }
    func resetWorkspace() {
        workspaceGeneration += 1; openGeneration += 1
        persistAll(); analysis?.cancel(); draftTask?.cancel(); hideCompletions()
        for doc in documents { doc.view.resignFirstResponder(); doc.view.removeFromSuperview() }
        documents = []; active = nil; job = nil
        if isViewLoaded { empty.isHidden = false; updateChrome(); projectDidChange(); view.setNeedsLayout() }
    }
    func projectDidChange() {
        guard isViewLoaded else { return }
        let project = environment.project
        let name = project.map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent }
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "doc.text")
        configuration.text = name ?? "No Open Files"
        configuration.button.title = project == nil ? "Browse Mac Files" : "Browse Project Files"
        configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.files() }
        empty.configuration = configuration
        if active == nil { title = name ?? "Orbit"; setStatus("Ready") }
        buildButton.menu = buildMenu()
        scheduleAnalysis()
    }
    func open(path: String) {
        loadViewIfNeeded()
        openGeneration += 1
        let generation = openGeneration, workspace = workspaceGeneration, peer = environment.peerID()
        if let existing = documents.first(where: { $0.draft.base.path == path && $0.peer == peer }) { activate(existing); return }
        setStatus("Opening " + (path as NSString).lastPathComponent + "…")
        Task {
            do {
                guard workspaceGeneration == workspace, openGeneration == generation, environment.peerID() == peer else { return }
                let cached = try environment.drafts.load(peer: peer, path: path)
                if let cached { install(cached, peer: peer) }
                let response = try await environment.client.call(CodeRequest(.open, path: path))
                guard workspaceGeneration == workspace, openGeneration == generation, environment.peerID() == peer else { return }
                guard let remote = response.document else { throw CodeFailure("The Mac did not return this file. Try opening it again.") }
                if let document = documents.first(where: { $0.draft.base.path == path && $0.peer == peer }) { acceptRemote(remote, for: document) }
                else { install(CodeDraft(base: remote), peer: peer) }
            } catch {
                guard workspaceGeneration == workspace, openGeneration == generation, environment.peerID() == peer else { return }
                if active?.draft.base.path == path { setStatus("Offline · draft on iPhone", color: .systemOrange) }
                else { setStatus("Couldn’t open file", color: .systemOrange); showError(error) }
            }
        }
    }
    private func install(_ draft: CodeDraft, peer: String) {
        let editor = CodeTextView(); editor.translatesAutoresizingMaskIntoConstraints = false
        editor.editorDelegate = self; editor.backgroundColor = .systemBackground
        editor.showLineNumbers = true; editor.lineHeightMultiplier = 1.22; editor.isFindInteractionEnabled = true
        editor.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 32, right: 16)
        editor.isLineWrappingEnabled = environment.defaults.object(forKey: "Code.wrap") as? Bool ?? true
        editor.autocorrectionType = .no; editor.autocapitalizationType = .none; editor.spellCheckingType = .no
        editor.smartQuotesType = .no; editor.smartDashesType = .no; editor.smartInsertDeleteType = .no
        editor.characterPairs = [Pair(leading: "(", trailing: ")"), Pair(leading: "[", trailing: "]"), Pair(leading: "{", trailing: "}"), Pair(leading: "\"", trailing: "\"")]
        editor.keyboardDismissMode = .interactive
        let state = makeState(text: draft.text, path: draft.base.path)
        editor.setState(state)
        if let endings = state.detectedLineEndings { editor.lineEndings = endings }
        switch state.detectedIndentStrategy { case .tab: editor.indentStrategy = .tab(length: 4); case .space(let length): editor.indentStrategy = .space(length: length); case .unknown: editor.indentStrategy = .space(length: 4) }
        editor.selectedRange = NSRange(location: min(draft.selection, (draft.text as NSString).length), length: 0)
        editor.inputAccessoryView = accessory(for: editor)
        editor.completionCommand = { [weak self] key in self?.completionKey(key) }
        let document = Document(draft: draft, view: editor, peer: peer)
        container.insertSubview(editor, belowSubview: completionTable)
        NSLayoutConstraint.activate([editor.leadingAnchor.constraint(equalTo: container.leadingAnchor), editor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.topAnchor.constraint(equalTo: container.topAnchor), editor.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        documents.append(document); activate(document); persist(document)
    }
    private func makeState(text: String, path: String) -> TextViewState {
        let theme = CodeTheme(size: fontSize)
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": return TextViewState(text: text, theme: theme, language: .swift)
        case "json", "xcstrings": return TextViewState(text: text, theme: theme, language: .json)
        case "js", "jsx": return TextViewState(text: text, theme: theme, language: .javaScript)
        case "c", "h", "m", "mm", "cpp", "hpp": return TextViewState(text: text, theme: theme, language: .c)
        default: return TextViewState(text: text, theme: theme)
        }
    }
    private func activate(_ document: Document) {
        environment.session.setLastFile(document.draft.base.path, peer: document.peer)
        if let active { persist(active) }
        let editing = active?.view.isFirstResponder == true
        active?.view.resignFirstResponder(); analysis?.cancel(); hideCompletions(); active = document
        for item in documents { item.view.isHidden = item !== document }
        empty.isHidden = true; title = (document.draft.base.path as NSString).lastPathComponent
        if editing { document.view.becomeFirstResponder() }
        updateChrome(); scheduleAnalysis(); view.setNeedsLayout()
    }
    private func updateChrome() {
        let presentation = documents.map {
            $0.draft.base.path + "|" + String($0.draft.modified) + "|" + String($0 === active)
        }.joined(separator: "\n")
        if presentation != tabPresentation {
            tabPresentation = presentation
            tabStack.arrangedSubviews.forEach { tabStack.removeArrangedSubview($0); $0.removeFromSuperview() }
            for doc in documents {
                let button = UIButton(type: .system)
                var configuration = UIButton.Configuration.plain()
                configuration.title = (doc.draft.modified ? "● " : "") + (doc.draft.base.path as NSString).lastPathComponent
                configuration.baseForegroundColor = doc === active ? .label : .secondaryLabel
                configuration.background.backgroundColor = doc === active ? .systemBackground : .clear
                configuration.cornerStyle = .capsule
                configuration.titleLineBreakMode = .byTruncatingMiddle
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
                button.configuration = configuration; button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
                button.addAction(UIAction { [weak self, weak doc] _ in if let doc { self?.activate(doc) } }, for: .touchUpInside)
                button.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
                button.accessibilityTraits = doc === active ? [.button, .selected] : .button
                tabStack.addArrangedSubview(button)
            }
        }
        navigationItem.rightBarButtonItems?.first?.menu = editorMenu()
        buildButton.menu = buildMenu()
        saveButton.isEnabled = active?.draft.modified == true && !saving
        guard let active else { positionLabel.text = nil; return }
        let pos = CodePosition.at(utf16Offset: active.view.selectedRange.location, in: active.view.text)
        positionLabel.text = "\(pos.line + 1):\(pos.character + 1)"
        if active.remote != nil { setStatus("Resolve Conflict", color: .systemOrange) }
        else if active.draft.modified { setStatus("Draft", color: .secondaryLabel) }
        else { setStatus("Saved to Mac", color: .secondaryLabel) }
    }
    private func setStatus(_ message: String, color: UIColor = .secondaryLabel) { status.setTitle(message, for: .normal); status.setTitleColor(color, for: .normal); status.accessibilityLabel = message }
    func textView(_ textView: TextView, canReplaceTextIn highlightedRange: HighlightedRange) -> Bool { true }
    func textViewDidChange(_ textView: TextView) {
        guard let doc = documents.first(where: { $0.view === textView }) else { return }
        doc.draft.text = textView.text; doc.draft.selection = textView.selectedRange.location; doc.generation += 1
        hideCompletions(); updateChrome(); scheduleAnalysis()
        draftTask?.cancel(); draftTask = Task { [weak self, weak doc] in
            try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled, let self, let doc else { return }; self.persist(doc)
        }
        let offset = textView.selectedRange.location
        if environment.project != nil, offset > 0 {
            let last = (textView.text as NSString).substring(with: NSRange(location: offset - 1, length: 1))
            if last == "." || last.rangeOfCharacter(from: .alphanumerics) != nil { requestCompletion() }
        }
    }
    func textViewDidChangeSelection(_ textView: TextView) {
        guard active?.view === textView else { return }
        if !completionTable.isHidden, textView.selectedRange != completionSelection { hideCompletions() }
        active?.draft.selection = textView.selectedRange.location
        let pos = CodePosition.at(utf16Offset: textView.selectedRange.location, in: textView.text)
        positionLabel.text = "\(pos.line + 1):\(pos.character + 1)"
    }
    private func persist(_ doc: Document) {
        do { try environment.drafts.save(doc.draft, peer: doc.peer) }
        catch { setStatus("Draft could not be saved", color: .systemRed) }
    }
    private func persistAll() { for doc in documents { persist(doc) } }
    @objc private func saveAction() { Task { _ = await saveActive() } }
    private func saveActive() async -> Bool {
        guard let doc = active else { return true }
        guard doc.peer == environment.peerID() else { showError(CodeFailure("This draft belongs to a different Mac. Reconnect that Mac before saving.")); return false }
        if !doc.draft.modified { return true }
        guard !saving else { return false }; saving = true; saveButton.isEnabled = false
        defer { saving = false; updateChrome() }
        persist(doc)
        let submitted = doc.draft.text
        let workspace = workspaceGeneration
        var request = CodeRequest(.save, path: doc.draft.base.path); request.text = submitted; request.version = doc.draft.base.version
        do {
            let response = try await environment.client.call(request)
            guard let remote = response.document else { throw CodeFailure("Couldn’t confirm the file was saved on your Mac. Check the file before trying again.") }
            if response.conflict {
                doc.remote = remote
                if workspaceGeneration == workspace, active === doc { resolveConflict(doc) }
                return false
            }
            doc.draft.base = remote; doc.remote = nil; persist(doc)
            return workspaceGeneration == workspace && environment.peerID() == doc.peer
        } catch { if workspaceGeneration == workspace { showError(error) }; return false }
    }
    private func acceptRemote(_ remote: CodeDocument, for doc: Document) {
        guard remote.version != doc.draft.base.version else { return }
        if doc.draft.modified { doc.remote = remote; if active === doc { updateChrome() }; return }
        let selection = doc.view.selectedRange; let offset = doc.view.contentOffset
        doc.draft = CodeDraft(base: remote, selection: min(selection.location, (remote.text as NSString).length))
        doc.view.setState(makeState(text: remote.text, path: remote.path), addUndoAction: true)
        doc.view.selectedRange = NSRange(location: doc.draft.selection, length: 0); doc.view.contentOffset = offset
        doc.generation += 1; persist(doc)
        if active === doc { updateChrome(); scheduleAnalysis() }
    }
    private func resolveConflict(_ doc: Document) {
        guard let remote = doc.remote else { return }
        let alert = UIAlertController(title: "This file changed on your Mac", message: "Choose which version to keep. Your iPhone draft is safe until you decide.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Use Mac Version", style: .destructive) { [weak self] _ in
            guard let self else { return }; doc.draft = CodeDraft(base: remote); doc.remote = nil
            doc.view.setState(self.makeState(text: remote.text, path: remote.path), addUndoAction: true); doc.generation += 1
            self.persist(doc); self.updateChrome(); self.scheduleAnalysis()
        })
        alert.addAction(UIAlertAction(title: "Use iPhone Version", style: .default) { [weak self] _ in
            guard let self else { return }; doc.draft.base = remote; doc.remote = nil; self.persist(doc)
            Task { _ = await self.saveActive() }
        })
        present(alert, animated: true)
    }
    private func refreshRemote() async {
        guard !polling, UIApplication.shared.applicationState == .active else { return }
        polling = true; defer { polling = false }
        if let job, job.state == .running { await refreshJob(job.id) }
        guard let doc = active, !saving, doc.peer == environment.peerID() else { return }
        do {
            var request = CodeRequest(.open, path: doc.draft.base.path); request.version = doc.draft.base.version
            let response = try await environment.client.call(request)
            if let remote = response.document { acceptRemote(remote, for: doc) }
        } catch { if active === doc { setStatus("Mac unavailable · draft on iPhone", color: .systemOrange) } }
    }
    private func scheduleAnalysis() {
        analysis?.cancel()
        guard let doc = active else { return }
        let generation = doc.generation; let text = doc.draft.text; let path = doc.draft.base.path
        analysis = Task { [weak self, weak doc] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let doc else { return }
            let local = path.hasSuffix(".swift") ? await Task.detached(priority: .utility) { CodeSyntax.diagnostics(text: text) }.value : []
            guard !Task.isCancelled, doc.generation == generation else { return }
            self.showDiagnostics(local, doc: doc, local: true)
            guard doc.peer == self.environment.peerID(), let project = self.environment.project, !project.scheme.isEmpty else { return }
            var request = CodeRequest(.analyze, path: path); request.project = project; request.text = text
            request.bufferVersion = Int(Date().timeIntervalSince1970 * 1000)
            do {
                let response = try await self.environment.client.call(request)
                guard !Task.isCancelled, doc.generation == generation else { return }
                self.showDiagnostics(response.diagnostics, doc: doc, local: false)
            } catch { if !Task.isCancelled, self.active === doc, local.isEmpty { self.setStatus("Local syntax OK · Mac checks unavailable", color: .systemOrange) } }
        }
    }
    private func showDiagnostics(_ diagnostics: [CodeDiagnostic], doc: Document, local: Bool) {
        doc.diagnostics = diagnostics
        doc.view.highlightedRanges = diagnostics.compactMap { diagnostic in
            guard let location = CodePosition(line: diagnostic.line, character: diagnostic.character).offset(in: doc.view.text) else { return nil }
            let length = min(1, (doc.view.text as NSString).length - location)
            return HighlightedRange(range: NSRange(location: location, length: length), color: (diagnostic.severity == 1 ? UIColor.systemRed : .systemOrange).withAlphaComponent(0.25))
        }
        guard active === doc, doc.remote == nil else { return }
        setStatus(diagnostics.isEmpty ? (local ? "Local syntax OK" : "Mac checks passed") + (doc.draft.modified ? " · Edited" : "") : "\(diagnostics.count) issue\(diagnostics.count == 1 ? "" : "s") · \(local ? "Syntax" : "Mac")", color: diagnostics.isEmpty ? .secondaryLabel : .systemOrange)
    }
    @objc private func showIssues() {
        if let doc = active, doc.remote != nil { resolveConflict(doc); return }
        guard let doc = active, !doc.diagnostics.isEmpty else { if job != nil { showBuildLog() }; return }
        let list = CodeListController(title: "Issues", rows: doc.diagnostics.map { "Line \($0.line + 1) · \($0.message)" }) { [weak self, weak doc] index in
            guard let self, let doc else { return }; self.dismiss(animated: true); _ = doc.view.goToLine(doc.diagnostics[index].line); doc.view.becomeFirstResponder()
        }
        present(UINavigationController(rootViewController: list), animated: true)
    }
    @objc private func requestCompletion() {
        guard let doc = active, doc.peer == environment.peerID(), let project = environment.project, !project.scheme.isEmpty else { setStatus("Choose a scheme in Project Settings for completion", color: .systemOrange); return }
        completionTask?.cancel(); let generation = doc.generation; let selection = doc.view.selectedRange
        var request = CodeRequest(.complete, path: doc.draft.base.path); request.text = doc.draft.text; request.project = project
        request.position = CodePosition.at(utf16Offset: selection.location, in: request.text); request.bufferVersion = Int(Date().timeIntervalSince1970 * 1000)
        completionTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                let response = try await environment.client.call(request)
                guard !Task.isCancelled, active === doc, doc.peer == environment.peerID(), doc.generation == generation, doc.view.selectedRange == selection else { return }
                completions = response.completions; completionIndex = 0; completionGeneration = generation; completionPath = doc.draft.base.path; completionSelection = selection
                completionTable.reloadData(); completionTable.isHidden = completions.isEmpty; doc.view.hasCompletions = !completions.isEmpty
                if completions.isEmpty { setStatus("No suggestions · Try building the project") }
                else { completionTable.selectRow(at: IndexPath(row: 0, section: 0), animated: false, scrollPosition: .top); placeCompletions() }
            } catch { if !Task.isCancelled { setStatus("Completion unavailable · Prepare project", color: .systemOrange) } }
        }
    }
    private func hideCompletions() { completionTask?.cancel(); completionTable.isHidden = true; active?.view.hasCompletions = false; completions = [] }
    private func placeCompletions() {
        guard !completionTable.isHidden, let editor = active?.view, let range = editor.selectedTextRange else { return }
        let caret = editor.convert(editor.caretRect(for: range.end), to: container)
        let width = min(430, max(220, container.bounds.width - 24))
        let height = min(CGFloat(completions.count) * 40, max(40, min(200, container.bounds.height * 0.48)))
        let below = caret.maxY + 5
        let y = below + height <= container.bounds.height ? below : max(0, caret.minY - height - 5)
        completionTable.frame = CGRect(x: max(8, min(caret.minX, container.bounds.width - width - 8)), y: y, width: width, height: height)
    }
    private func completionKey(_ key: String) {
        if key == UIKeyCommand.inputEscape { hideCompletions(); return }
        if key == "\r" || key == "\t" { insertCompletion(completionIndex); return }
        completionIndex = max(0, min(completions.count - 1, completionIndex + (key == UIKeyCommand.inputDownArrow ? 1 : -1)))
        completionTable.selectRow(at: IndexPath(row: completionIndex, section: 0), animated: true, scrollPosition: .middle)
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { completions.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil); let completion = completions[indexPath.row]
        cell.textLabel?.text = completion.label; cell.textLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        cell.detailTextLabel?.text = completion.detail; cell.detailTextLabel?.font = .systemFont(ofSize: 10); return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { insertCompletion(indexPath.row) }
    private func insertCompletion(_ index: Int) {
        guard let doc = active, completions.indices.contains(index), doc.generation == completionGeneration, doc.draft.base.path == completionPath, doc.view.selectedRange == completionSelection else { hideCompletions(); return }
        let item = completions[index]; var range = doc.view.selectedRange
        if let start = item.start?.offset(in: doc.view.text), let end = item.end?.offset(in: doc.view.text), end >= start { range = NSRange(location: start, length: end - start) }
        hideCompletions(); doc.view.replace(range, withText: item.text)
        doc.view.selectedRange = NSRange(location: range.location + (item.text as NSString).length, length: 0)
        textViewDidChange(doc.view)
    }
    private func accessory(for editor: CodeTextView) -> UIView {
        let accessory = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 40), inputViewStyle: .keyboard)
        let scroll = UIScrollView(); scroll.showsHorizontalScrollIndicator = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(scroll)
        let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 2; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        func button(_ title: String, label: String? = nil, action: @escaping () -> Void) {
            let b = UIButton(type: .system); b.setTitle(title, for: .normal); b.titleLabel?.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
            b.accessibilityLabel = label ?? title; b.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            b.addAction(UIAction { _ in action() }, for: .touchUpInside); stack.addArrangedSubview(b)
        }
        button("⇥", label: "Indent") { [weak editor] in editor?.shiftRight() }
        button("⇤", label: "Outdent") { [weak editor] in editor?.shiftLeft() }
        button("↶", label: "Undo") { [weak editor] in editor?.undoManager?.undo() }
        button("↷", label: "Redo") { [weak editor] in editor?.undoManager?.redo() }
        for symbol in ["{", "}", "(", ")", "[", "]", "\"", ".", ":", "=", "_"] { button(symbol) { [weak editor] in editor?.insertText(symbol) } }
        button("⌘", label: "Code Completion") { [weak self] in self?.requestCompletion() }
        button("⌄", label: "Dismiss Keyboard") { [weak editor] in editor?.resignFirstResponder() }
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: accessory.safeAreaLayoutGuide.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: accessory.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: accessory.topAnchor), scroll.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)])
        return accessory
    }
    private func editorMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Find & Replace", image: UIImage(systemName: "magnifyingglass"), attributes: active == nil ? .disabled : []) { [weak self] _ in self?.findInFile() },
            UIAction(title: "Code Completion", image: UIImage(systemName: "text.cursor"), attributes: active == nil ? .disabled : []) { [weak self] _ in self?.requestCompletion() },
            UIAction(title: "Toggle Comment", image: UIImage(systemName: "text.bubble"), attributes: active == nil ? .disabled : []) { [weak self] _ in self?.comment() },
            UIAction(title: "Toggle Line Wrapping", image: UIImage(systemName: "arrow.turn.down.left"), attributes: active == nil ? .disabled : []) { [weak self] _ in self?.wrap() },
            UIAction(title: "Larger Text", image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in self?.resize(1) },
            UIAction(title: "Smaller Text", image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in self?.resize(-1) },
            UIAction(title: "Open File…", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in self?.quickOpen() },
            UIAction(title: "Acknowledgements", image: UIImage(systemName: "info.circle")) { [weak self] _ in self?.acknowledgements() },
            UIAction(title: "Close File", image: UIImage(systemName: "xmark"), attributes: active == nil ? .disabled : []) { [weak self] _ in self?.closeFile() }
        ])
    }
    private func acknowledgements() {
        let controller = UIViewController(); controller.title = "Acknowledgements"
        let text = UITextView(); text.isEditable = false; text.font = .preferredFont(forTextStyle: .footnote)
        text.text = Bundle.module.url(forResource: "Acknowledgements", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        controller.view = text
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        present(UINavigationController(rootViewController: controller), animated: true)
    }
    private func buildMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Build", image: UIImage(systemName: "hammer")) { [weak self] _ in self?.startJob(.build) },
            UIAction(title: "Build & Deploy to TestFlight", image: UIImage(systemName: "paperplane")) { [weak self] _ in self?.startJob(.deploy) },
            UIAction(title: "Prepare Code Intelligence", image: UIImage(systemName: "text.badge.checkmark")) { [weak self] _ in self?.startJob(.prepare) },
            UIAction(title: "Choose Build Scheme…", image: UIImage(systemName: "list.bullet"), attributes: environment.project == nil ? .disabled : []) { [weak self] _ in self?.chooseScheme() },
            UIAction(title: "Project Settings", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in self?.configureProject() },
            UIAction(title: "Build Log", image: UIImage(systemName: "terminal"), attributes: job == nil ? .disabled : []) { [weak self] _ in self?.showBuildLog() },
            UIAction(title: "Cancel Build", image: UIImage(systemName: "stop"), attributes: job?.state == .running ? [] : .disabled) { [weak self] _ in self?.cancelJob() }
        ])
    }
    @objc private func findInFile() { active?.view.findInteraction?.presentFindNavigator(showingReplace: true) }
    @objc private func wrap() { guard let editor = active?.view else { return }; editor.isLineWrappingEnabled.toggle(); environment.defaults.set(editor.isLineWrappingEnabled, forKey: "Code.wrap") }
    private func resize(_ amount: CGFloat) { fontSize = max(11, min(28, fontSize + amount)); environment.defaults.set(fontSize, forKey: "Code.fontSize"); documents.forEach { $0.view.theme = CodeTheme(size: fontSize) } }
    @objc private func comment() {
        guard let editor = active?.view else { return }
        let ns = editor.text as NSString; let range = ns.lineRange(for: editor.selectedRange)
        let lines = ns.substring(with: range).components(separatedBy: "\n")
        let uncomment = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let changed = lines.map { line -> String in
            if line.isEmpty { return line }
            let prefix = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let rest = String(line.dropFirst(prefix.count))
            return prefix + (uncomment && rest.hasPrefix("//") ? String(rest.dropFirst(2)).replacingOccurrences(of: "^ ", with: "", options: .regularExpression) : "// " + rest)
        }.joined(separator: "\n")
        editor.replace(range, withText: changed); textViewDidChange(editor)
    }
    @objc private func quickOpen() {
        let alert = UIAlertController(title: "Open Source File", message: "Enter its absolute path on your Mac.", preferredStyle: .alert)
        alert.addTextField { $0.text = self.environment.project?.root.appending("/"); $0.autocorrectionType = .no; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in if let path = alert.textFields?.first?.text { self?.open(path: path) } })
        present(alert, animated: true)
    }
    @objc private func closeFile() {
        guard let doc = active else { return }; persist(doc)
        openGeneration += 1; analysis?.cancel(); hideCompletions()
        doc.view.resignFirstResponder(); doc.view.removeFromSuperview(); documents.removeAll { $0 === doc }; active = nil
        if let next = documents.last { activate(next) } else { environment.session.setLastFile(nil, peer: doc.peer); empty.isHidden = false; updateChrome(); projectDidChange(); view.setNeedsLayout(); openFiles?() }
    }
    func configureProject(from presenter: UIViewController? = nil) {
        let presenter = presenter ?? self
        let peer = environment.peerID()
        let settings = CodeProjectSettingsController(project: environment.project) { [weak self, weak presenter] project in
            guard let self, let presenter, peer == self.environment.peerID() else { return }
            self.environment.project = project
            if project.scheme.isEmpty {
                let visible = (self.splitViewController?.viewController(for: .primary) as? UINavigationController)?.topViewController
                self.chooseScheme(from: presenter.viewIfLoaded?.window == nil ? (visible ?? self) : presenter)
            } else { self.scheduleAnalysis() }
        }
        presenter.present(UINavigationController(rootViewController: settings), animated: true)
    }

    func chooseScheme(from presenter: UIViewController? = nil, completion: (() -> Void)? = nil) {
        guard let project = environment.project, !loadingSchemes else { return }
        let presenter = presenter ?? self, peer = environment.peerID()
        loadingSchemes = true
        let list = CodeListController(title: "Choose Scheme", rows: [], select: { _ in })
        list.showLoading()
        presenter.present(UINavigationController(rootViewController: list), animated: true)
        Task {
            defer { loadingSchemes = false }
            do {
                let response = try await environment.client.call(CodeRequest(.schemes, path: project.path))
                guard peer == environment.peerID(), environment.project?.path == project.path, list.presentingViewController != nil || list.navigationController?.presentingViewController != nil else { return }
                let schemes = response.schemes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                list.setRows(schemes, emptyMessage: "No schemes found. Open this project in Xcode on your Mac and create or share a scheme.") { [weak self, weak list] index in
                    guard let self, peer == self.environment.peerID(), self.environment.project?.path == project.path else { return }
                    self.environment.project?.scheme = schemes[index]
                    list?.dismiss(animated: true) { self.scheduleAnalysis(); completion?() }
                }
            } catch { list.showMessage(error.localizedDescription + "\nClose this sheet and try again when your Mac is available.") }
        }
    }
    private func startJob(_ operation: CodeRequest.Operation) {
        guard let project = environment.project else { configureProject(); return }
        guard !project.scheme.isEmpty else { chooseScheme { [weak self] in self?.startJob(operation) }; return }
        guard operation != .deploy || (!project.appID.isEmpty && !project.groupID.isEmpty) else {
            configureProject(); return
        }
        guard !startingJob else { return }
        do { try environment.builds.begin(title: operation == .deploy ? "Build & Deploy" : "Build · " + project.scheme) }
        catch { showError(error); return }
        startingJob = true
        let workspace = workspaceGeneration, peer = environment.peerID()
        Task {
            defer { startingJob = false; environment.builds.endStarting(peer: peer) }
            let original = active
            for doc in documents where doc.draft.modified {
                guard workspaceGeneration == workspace, environment.peerID() == peer else { return }
                activate(doc); guard await saveActive() else { return }
            }
            guard workspaceGeneration == workspace, environment.peerID() == peer, environment.project == project else { return }
            if let original { activate(original) }
            var request = CodeRequest(operation); request.project = project
            do {
                let response = try await environment.client.call(request)
                // Keep the originating Mac association even if the user switches while waiting.
                environment.defaults.set(response.job?.id, forKey: "Code.job." + peer)
                guard environment.peerID() == peer else { return }
                guard let accepted = response.job else { throw CodeFailure("The Mac did not confirm the build. Update Orbit Mac and try again.") }
                environment.builds.accept(accepted)
                guard workspaceGeneration == workspace else { return }
                job = accepted; buildButton.menu = buildMenu(); showBuildLog(showConsole: false)
            } catch { if workspaceGeneration == workspace { showError(error) } }
        }
    }
    private func refreshJob(_ id: String) async {
        let peer = environment.peerID(), workspace = workspaceGeneration
        var request = CodeRequest(.job); request.jobID = id
        if let response = try? await environment.client.call(request), peer == environment.peerID(), workspace == workspaceGeneration { job = response.job; if let job { environment.builds.observe(job) } }
        buildButton?.menu = buildMenu()
        if let log = (presentedViewController as? UINavigationController)?.topViewController as? CodeLogController { log.update(job) }
    }
    private func showBuildLog(showConsole: Bool = true) {
        guard let job else { showError(CodeFailure("No build yet. Select a project, then choose Build or Build & Deploy.")); return }
        let log = CodeLogController(job: job, showConsole: showConsole, monitor: environment.builds); present(UINavigationController(rootViewController: log), animated: true)
    }
    private func cancelJob() {
        guard let job else { return }; var request = CodeRequest(.cancel); request.jobID = job.id
        Task { do { self.job = try await environment.client.call(request).job } catch { showError(error) } }
    }
    private func showError(_ error: Error, from presenter: UIViewController? = nil) {
        let presenter = presenter ?? self
        guard presenter.presentedViewController == nil else { setStatus(error.localizedDescription, color: .systemRed); return }
        let alert = UIAlertController(title: "Orbit", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); presenter.present(alert, animated: true)
    }
    override var keyCommands: [UIKeyCommand]? {
        [("s", UIKeyModifierFlags.command, #selector(saveAction), "Save to Mac"),
         ("f", .command, #selector(findInFile), "Find & Replace"), ("o", [.command, .shift], #selector(quickOpen), "Open File"),
         ("/", .command, #selector(comment), "Toggle Comment"), ("w", .command, #selector(closeFile), "Close File"),
         (" ", .control, #selector(requestCompletion), "Complete Code"), ("b", .command, #selector(buildShortcut), "Build"),
         ("[", .command, #selector(outdent), "Outdent"), ("]", .command, #selector(indent), "Indent"),
         ("1", .command, #selector(files), "Project Files")].map { input, modifiers, action, title in
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action); command.discoverabilityTitle = title; command.wantsPriorityOverSystemBehavior = true; return command
         }
    }
    @objc private func buildShortcut() { startJob(.build) }
    @objc private func indent() { active?.view.shiftRight() }
    @objc private func outdent() { active?.view.shiftLeft() }
}

@MainActor final class CodeListController: UITableViewController {
    private var rows: [String]; private var select: (Int) -> Void
    init(title: String, rows: [String], select: @escaping (Int) -> Void) { self.rows = rows; self.select = select; super.init(style: .insetGrouped); self.title = title }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }) }
    func showLoading(_ message: String = "Reading Xcode schemes…") {
        loadViewIfNeeded()
        var config = UIContentUnavailableConfiguration.loading(); config.text = message
        tableView.backgroundView = UIContentUnavailableView(configuration: config)
    }
    func showMessage(_ message: String) {
        var config = UIContentUnavailableConfiguration.empty(); config.text = "Unavailable"; config.secondaryText = message
        tableView.backgroundView = UIContentUnavailableView(configuration: config)
    }
    func setRows(_ rows: [String], emptyMessage: String, select: @escaping (Int) -> Void) {
        self.rows = rows; self.select = select; tableView.backgroundView = nil
        tableView.reloadData()
        if rows.isEmpty { showMessage(emptyMessage) }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil); cell.textLabel?.text = rows[indexPath.row]; cell.textLabel?.numberOfLines = 0; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { select(indexPath.row) }
}
@MainActor final class CodeLogController: UIViewController {
    private let text = UITextView()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let percent = UILabel()
    private let work = UILabel()
    private weak var monitor: CodeBuildMonitor?
    private let status = UILabel()
    private let detail = UILabel()
    private let console = UIButton(type: .system)
    private var summary: UIStackView!
    private var job: CodeJob
    private var showConsole: Bool
    var jobID: String { job.id }
    init(job: CodeJob, showConsole: Bool = false, monitor: CodeBuildMonitor) {
        self.monitor = monitor
        self.job = job; self.showConsole = showConsole; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.isEditable = false; text.translatesAutoresizingMaskIntoConstraints = false
        text.accessibilityIdentifier = "CodeBuildConsole"
        status.font = .preferredFont(forTextStyle: .title2); status.textAlignment = .center; status.numberOfLines = 0
        status.adjustsFontForContentSizeCategory = true
        detail.adjustsFontForContentSizeCategory = true; detail.textColor = .secondaryLabel
        detail.font = .preferredFont(forTextStyle: .body); detail.textAlignment = .center; detail.numberOfLines = 0
        detail.accessibilityIdentifier = "CodeBuildStatus"
        progress.isAccessibilityElement = true
        progress.accessibilityLabel = "Build progress"
        progress.accessibilityIdentifier = "CodeBuildProgress"
        percent.font = .preferredFont(forTextStyle: .headline); percent.textAlignment = .center
        percent.adjustsFontForContentSizeCategory = true
        NotificationCenter.default.addObserver(self, selector: #selector(buildChanged), name: CodeBuildMonitor.changed, object: monitor)
        work.font = .preferredFont(forTextStyle: .subheadline); work.textAlignment = .center
        work.adjustsFontForContentSizeCategory = true; work.numberOfLines = 0
        work.accessibilityIdentifier = "CodeBuildWork"
        summary = UIStackView(arrangedSubviews: [status, progress, percent, work, detail]); summary.axis = .vertical; summary.spacing = 20
        summary.translatesAutoresizingMaskIntoConstraints = false
        console.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.showConsole.toggle(); self.update(self.job)
        }, for: .touchUpInside)
        console.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summary); view.addSubview(text); view.addSubview(console)
        NSLayoutConstraint.activate([
            summary.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), summary.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            console.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16), console.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            text.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), text.bottomAnchor.constraint(equalTo: console.topAnchor, constant: -12),
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor), text.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }); update(job)
    }
    @objc private func buildChanged() {
        guard let monitor, monitor.job?.id == job.id else { return }
        update(monitor.job)
    }
    func update(_ value: CodeJob?) {
        guard let value else { return }; job = value
        guard isViewLoaded else { return }
        title = value.title
        text.isHidden = !showConsole; summary.isHidden = showConsole
        text.text = value.log.isEmpty ? "Starting on your Mac…" : value.log
        console.setTitle(showConsole ? "Hide Console" : "Show Console", for: .normal)
        let fraction = monitor?.fraction(for: value) ?? value.progressFraction()
        progress.progress = Float(fraction)
        work.text = value.progressDetail; work.isHidden = value.progressDetail == nil
        progress.accessibilityValue = "\(Int(fraction * 100)) percent estimated"
        percent.text = value.state == .running ? "\(Int(fraction * 100))% · Estimated" : (value.state == .succeeded ? "100%" : nil)
        progress.isHidden = value.state == .failed || value.state == .cancelled
        detail.isHidden = value.state == .succeeded || value.state == .cancelled
        switch value.state {
        case .running:
            status.text = value.installHandoff == nil ? value.progressStage : "Build Complete — Updating Orbit"
            detail.text = monitor?.backgroundMessage ?? "You can leave Orbit while your Mac builds."
        case .succeeded: status.text = "Build Completed"; detail.text = nil
        case .failed:
            status.text = "Build Failed"
            detail.text = value.failureMessage ?? "Your Mac couldn’t complete this job. Open the console for details."
        case .cancelled: status.text = "Build Cancelled"; detail.text = nil
        }
    }
}
#endif
