import SwiftUI
import OrbitWidgets

public struct OrbitWidgetView: View {
    public let node: OrbitWidgetNode
    public init(node: OrbitWidgetNode) { self.node = node }
    public var body: some View { content.foregroundStyle(color) }
    private var content: AnyView {
        switch node.type {
        case "text": return AnyView(Text(node.text ?? "").font(.system(size: node.size ?? 16, weight: weight)).lineLimit(6).minimumScaleFactor(0.7))
        case "symbol": return AnyView(Image(systemName: node.symbol ?? "sparkles").font(.system(size: node.size ?? 24, weight: weight)))
        case "date": return AnyView(Text(node.date ?? Date(), style: .relative).font(.system(size: node.size ?? 16, weight: weight)))
        case "hstack": return AnyView(HStack(spacing: node.spacing ?? 8) { children })
        case "vstack": return AnyView(VStack(alignment: .leading, spacing: node.spacing ?? 8) { children })
        case "spacer": return AnyView(Spacer(minLength: node.spacing ?? 0))
        default: return AnyView(EmptyView())
        }
    }
    @ViewBuilder private var children: some View {
        ForEach(Array((node.children ?? []).enumerated()), id: \.offset) { _, child in OrbitWidgetView(node: child) }
    }
    private var weight: Font.Weight {
        switch node.weight { case "bold": return .bold; case "semibold": return .semibold; case "medium": return .medium; default: return .regular }
    }
    private var color: Color {
        switch node.color {
        case "secondary": return .secondary
        case "accent": return .accentColor
        case "red": return .red
        case "orange": return .orange
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        default: return .primary
        }
    }
}
