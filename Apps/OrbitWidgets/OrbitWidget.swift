import WidgetKit
import SwiftUI
import AppIntents
import OrbitWidgets
import OrbitWidgetUI

struct ScriptEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Orbit Widget"
    static let defaultQuery = ScriptQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct ScriptQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ScriptEntity] {
        try OrbitWidgetStore().scripts().filter { identifiers.contains($0.id) }.map { .init(id: $0.id, name: $0.definition.name) }
    }
    func suggestedEntities() async throws -> [ScriptEntity] { try OrbitWidgetStore().scripts().map { .init(id: $0.id, name: $0.definition.name) } }
    func defaultResult() async -> ScriptEntity? { try? await suggestedEntities().first }
}
struct ScriptConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a Widget"
    static let description = IntentDescription("Choose a JavaScript widget you’ve added in Orbit.")
    @Parameter(title: "Widget") var script: ScriptEntity?
}
struct ScriptEntry: TimelineEntry {
    var date: Date
    var node: OrbitWidgetNode?
    var message: String?
    var stale = false
}
struct ScriptProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ScriptEntry { .init(date: Date(), node: .init(type: "text", text: "Your widget")) }
    func snapshot(for configuration: ScriptConfiguration, in context: Context) async -> ScriptEntry {
        let store = OrbitWidgetStore(), family = familyName(context.family)
        if let id = configuration.script?.id, let output = try? store.output(id, family: family), let entry = output.entries.first {
            return .init(date: entry.date, node: entry.view)
        }
        return placeholder(in: context)
    }
    func timeline(for configuration: ScriptConfiguration, in context: Context) async -> Timeline<ScriptEntry> {
        let store = OrbitWidgetStore(), family = familyName(context.family), now = Date()
        guard let id = configuration.script?.id, let script = try? store.script(id) else {
            return Timeline(entries: [.init(date: now, message: "Choose a widget in Edit Widget.")], policy: .never)
        }
        let interval = Double(script.definition.refreshMinutes) * 60
        let cached = try? store.output(id, family: family)
        // A preview or another timeline request may already have refreshed this
        // family. Honor the requested minimum interval instead of refetching.
        if let cached, now.timeIntervalSince(cached.updatedAt) < interval {
            return makeTimeline(cached, after: cached.updatedAt.addingTimeInterval(interval), now: now)
        }
        do {
            let output = try await OrbitWidgetRuntime.run(script: script, storage: store.storage(id), family: family, now: now)
            try store.save(output, script: script, family: family)
            return makeTimeline(output, after: now.addingTimeInterval(interval), now: now)
        } catch {
            if let cached { return makeTimeline(cached, after: now.addingTimeInterval(interval), now: now, stale: true) }
            return Timeline(entries: [.init(date: now, message: "Open Orbit to check this widget.")], policy: .after(now.addingTimeInterval(interval)))
        }
    }
    private func makeTimeline(_ output: OrbitWidgetOutput, after: Date, now: Date, stale: Bool = false) -> Timeline<ScriptEntry> {
        let current = output.entries.last(where: { $0.date <= now }) ?? output.entries[0]
        let entries = [ScriptEntry(date: now, node: current.view, stale: stale)] + output.entries.filter { $0.date > now }.map { .init(date: $0.date, node: $0.view, stale: stale) }
        return Timeline(entries: entries, policy: .after(max(after, now.addingTimeInterval(60))))
    }
    private func familyName(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: return "small"
        case .systemMedium: return "medium"
        case .systemLarge: return "large"
        case .accessoryCircular: return "circular"
        case .accessoryRectangular: return "rectangular"
        case .accessoryInline: return "inline"
        default: return "small"
        }
    }
}
struct ScriptWidgetView: View {
    var entry: ScriptEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let node = entry.node { OrbitWidgetView(node: node) }
            else { Text(entry.message ?? "Add a widget in Orbit.").font(.caption) }
            if entry.stale { Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Data may be out of date") }
        }.containerBackground(.fill.tertiary, for: .widget)
    }
}
@main struct OrbitScriptWidget: Widget {
    let kind = "Orbit.JavaScript"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ScriptConfiguration.self, provider: ScriptProvider()) { entry in ScriptWidgetView(entry: entry) }
            .configurationDisplayName("Orbit")
            .description("Widgets made with JavaScript.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
