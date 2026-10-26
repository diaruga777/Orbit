import SwiftUI
#if canImport(OrbitWidgets)
import OrbitWidgets
#endif

/// Used by Orbit and exported standalone hosts. A single invocation owns each write.
public struct OrbitAppletView: View {
    private let script: OrbitWidgetScript
    private let store: OrbitWidgetStore
    @State private var node: OrbitWidgetNode?
    @State private var inputs: [String: String] = [:]
    @State private var busy = false
    @State private var failure: String?
    @State private var invocation: Task<Void, Never>?
    public init(script: OrbitWidgetScript, store: OrbitWidgetStore) { self.script = script; self.store = store }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let node { OrbitAppletNodeView(node: node, inputs: $inputs, send: send) }
                if busy { ProgressView("Loading…") }
                if let failure { Text(failure).foregroundStyle(.red).accessibilityIdentifier("applet.error") }
                if let consent = try? OrbitAppletDefinition.parse(script.source).pollingConsent {
                    Text(consent).font(.footnote).foregroundStyle(.secondary)
                    if let state = try? store.pollingState(script.id) {
                        if let date = state.lastSuccess { Text("Last checked " + date.formatted()).font(.footnote) }
                        if let error = state.failure { Text(error).font(.footnote).foregroundStyle(.red) }
                    }
                    #if os(iOS)
                    if let error = OrbitAppletBackground.shared.schedulingFailure { Text(error).font(.footnote).foregroundStyle(.red) }
                    #endif
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading).disabled(busy)
        }
        .navigationTitle(script.definition.name)
        .toolbar { Button("Reload", systemImage: "arrow.clockwise") { run(nil) }.disabled(busy) }
        .task { run(nil) }
        .onDisappear { invocation?.cancel(); invocation = nil }
    }
    private func send(_ action: String) { run(OrbitAppletEvent(action: action, values: inputs)) }
    private func run(_ event: OrbitAppletEvent?) {
        guard !busy else { return }
        busy = true; failure = nil
        invocation = Task { @MainActor in
            defer { busy = false }
            do {
                #if os(iOS)
                if event == nil {
                    await OrbitAppletBackground.shared.requestPermissionIfNeeded()
                    do { try await OrbitAppletBackground.shared.check(script) }
                    catch { failure = error.localizedDescription }
                    await OrbitAppletBackground.shared.schedule()
                }
                #endif
                let output = try await OrbitAppletRunner.shared.run(script: script, store: store, event: event)
                try Task.checkCancellation()
                node = output.entries.first?.view
                inputs = [:]
                if let node { collectInputs(node) }
            } catch is CancellationError { } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
    private func collectInputs(_ node: OrbitWidgetNode) {
        if let key = node.key {
            inputs[key] = node.type == "toggle" ? String(node.isOn ?? false) : (node.value ?? "")
        }
        for child in node.children ?? [] { collectInputs(child) }
    }
}

private struct OrbitAppletNodeView: View {
    let node: OrbitWidgetNode
    @Binding var inputs: [String: String]
    let send: (String) -> Void
    var body: some View { content.foregroundStyle(color) }
    private var content: AnyView {
        switch node.type {
        case "button": return AnyView(Button(node.text ?? "Continue") { send(node.action ?? "") }.buttonStyle(.borderedProminent))
        case "textfield": return AnyView(TextField(node.text ?? "", text: Binding(get: { inputs[node.key ?? ""] ?? "" }, set: { inputs[node.key ?? ""] = String($0.prefix(2000)) })).textFieldStyle(.roundedBorder).onSubmit { send(node.action ?? "") }.accessibilityIdentifier("applet.input." + (node.key ?? "")))
        case "toggle": return AnyView(Toggle(node.text ?? "", isOn: Binding(get: { inputs[node.key ?? ""] == "true" }, set: { inputs[node.key ?? ""] = String($0); send(node.action ?? "") })))
        case "divider": return AnyView(Divider())
        case "hstack": return AnyView(HStack(spacing: node.spacing ?? 8) { children })
        case "vstack": return AnyView(VStack(alignment: .leading, spacing: node.spacing ?? 8) { children })
        case "spacer": return AnyView(Spacer(minLength: node.spacing ?? 0))
        case "symbol": return AnyView(Image(systemName: node.symbol ?? "sparkles").font(.system(size: node.size ?? 24, weight: weight)))
        case "date": return AnyView(Text(node.date ?? Date(), style: .relative))
        default: return AnyView(Text(node.text ?? "").font(.system(size: node.size ?? 17, weight: weight)))
        }
    }
    private var children: some View {
        ForEach(Array((node.children ?? []).enumerated()), id: \.offset) { _, child in OrbitAppletNodeView(node: child, inputs: $inputs, send: send) }
    }
    private var weight: Font.Weight { switch node.weight { case "bold": return .bold; case "semibold": return .semibold; case "medium": return .medium; default: return .regular } }
    private var color: Color { switch node.color { case "secondary": return .secondary; case "accent": return .accentColor; case "red": return .red; case "orange": return .orange; case "green": return .green; case "blue": return .blue; case "purple": return .purple; default: return .primary } }
}
