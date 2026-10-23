import Foundation
import CryptoKit

public struct OrbitWidgetError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Metadata is parsed without evaluating code, before the user grants access.
public struct OrbitWidgetDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var domains: [String]
    public var refreshMinutes: Int
    public static let maximumSourceBytes = 128 * 1024
    public static func parse(_ source: String) throws -> Self {
        guard source.utf8.count <= maximumSourceBytes,
              source.hasPrefix("/* orbit-widget\n"), let end = source.range(of: "*/") else {
            throw OrbitWidgetError("Choose a JavaScript file with an Orbit widget header.")
        }
        let json = String(source[source.index(source.startIndex, offsetBy: 16)..<end.lowerBound])
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
        catch { throw OrbitWidgetError("The widget header needs an id, name, domains, and refreshMinutes.") }
        guard !value.id.isEmpty, value.id.count <= 64,
              value.id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }),
              !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.name.count <= 80,
              (15...1440).contains(value.refreshMinutes), value.domains.count <= 16,
              value.domains.allSatisfy(Self.validDomain) else {
            throw OrbitWidgetError("Check the widget’s name, domains, and refresh interval (15–1440 minutes).")
        }
        return value
    }
    private static func validDomain(_ value: String) -> Bool {
        guard value == value.lowercased(), value.count <= 253, value.contains("."), !value.hasSuffix("."),
              !value.contains(".."), !value.contains(":"), !value.contains("/"), !value.contains("*"),
              !value.hasSuffix(".local"), value != "localhost",
              !value.split(separator: ".").allSatisfy({ Int($0) != nil }) else { return false }
        return value.split(separator: ".").allSatisfy { part in
            !part.isEmpty && part.count <= 63 && part.first != "-" && part.last != "-" &&
                part.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }
        }
    }
    public func permits(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) &&
            domains.contains(url.host?.lowercased() ?? "")
    }
    public static func digest(_ source: String) -> String { SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public struct OrbitWidgetScript: Codable, Identifiable, Sendable {
    public var definition: OrbitWidgetDefinition
    public var source: String
    public var installedAt: Date
    public var id: String { definition.id }
    init(definition: OrbitWidgetDefinition, source: String) { self.definition = definition; self.source = source; installedAt = Date() }
    public init(source: String) throws { definition = try .parse(source); self.source = source; installedAt = Date() }
}

public struct OrbitWidgetNode: Codable, Equatable, Sendable {
    public var type: String
    public var text: String?
    public var symbol: String?
    public var size: Double?
    public var weight: String?
    public var color: String?
    public var spacing: Double?
    public var children: [OrbitWidgetNode]?
    public var action: String?
    public var key: String?
    public var value: String?
    public var isOn: Bool?
    public var date: Date?
    public init(type: String, text: String? = nil) { self.type = type; self.text = text }
    public func validate(depth: Int = 0, count: inout Int, interactive: Bool = false) throws {
        count += 1
        guard count <= 120, depth <= 8, (["text", "symbol", "vstack", "hstack", "spacer", "date"] + (interactive ? ["button", "textfield", "toggle", "divider"] : [])).contains(type),
              (text?.count ?? 0) <= 2000, (symbol?.count ?? 0) <= 80,
              size.map({ $0.isFinite && (8...72).contains($0) }) ?? true,
              spacing.map({ $0.isFinite && (0...40).contains($0) }) ?? true,
              color.map({ ["primary", "secondary", "accent", "red", "orange", "green", "blue", "purple"].contains($0) }) ?? true,
              weight.map({ ["regular", "medium", "semibold", "bold"].contains($0) }) ?? true else {
            throw OrbitWidgetError("This widget returned an unsupported layout.")
        }
        if ["button", "textfield", "toggle"].contains(type) {
            guard let action, !action.isEmpty, action.count <= 128,
                  type == "button" || (key.map { !$0.isEmpty && $0.count <= 128 } ?? false),
                  (value?.count ?? 0) <= 2000, (children?.isEmpty ?? true) else { throw OrbitWidgetError("Controls need a short action and input key.") }
        }
        for child in children ?? [] { try child.validate(depth: depth + 1, count: &count, interactive: interactive) }
        if interactive && depth == 0 { var keys = Set<String>(); try validateInputKeys(&keys) }
    }
    private func validateInputKeys(_ keys: inout Set<String>) throws {
        if ["textfield", "toggle"].contains(type), let key {
            guard keys.insert(key).inserted else { throw OrbitWidgetError("Each applet input needs a unique key.") }
        }
        for child in children ?? [] { try child.validateInputKeys(&keys) }
    }
}

public struct OrbitWidgetEntry: Codable, Sendable {
    public var date: Date
    public var view: OrbitWidgetNode
    public init(date: Date, view: OrbitWidgetNode) { self.date = date; self.view = view }
}
public struct OrbitWidgetOutput: Codable, Sendable {
    public var entries: [OrbitWidgetEntry]
    public var storage: [String: String]
    public var updatedAt: Date
    public var failure: String?
    public init(entries: [OrbitWidgetEntry], storage: [String: String], updatedAt: Date, failure: String? = nil) {
        self.entries = entries; self.storage = storage; self.updatedAt = updatedAt; self.failure = failure
    }
}
