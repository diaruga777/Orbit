import Foundation

/// File imports inspect only the inert header. JavaScript is never evaluated here.
public struct OrbitJavaScriptFile: Sendable {
    public enum Kind: String, Codable, Sendable { case applet, widget }
    public let kind: Kind
    public let script: OrbitWidgetScript
    public init(source: String) throws {
        if source.hasPrefix("/* orbit-applet\n") {
            kind = .applet; script = try OrbitAppletDefinition.widgetScript(source)
        } else {
            kind = .widget; script = try OrbitWidgetScript(source: source)
        }
    }
    public init(url: URL, requireJavaScriptExtension: Bool = true) throws {
        guard url.isFileURL, (!requireJavaScriptExtension || url.pathExtension.lowercased() == "js") else { throw OrbitWidgetError("Choose an Orbit .js file.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= OrbitWidgetDefinition.maximumSourceBytes else {
            throw OrbitWidgetError("Choose a JavaScript file under 128 KB.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: OrbitWidgetDefinition.maximumSourceBytes + 1) ?? Data()
        guard data.count <= OrbitWidgetDefinition.maximumSourceBytes, let source = String(data: data, encoding: .utf8) else {
            throw OrbitWidgetError("Choose a UTF-8 JavaScript file under 128 KB.")
        }
        try self.init(source: source)
    }
}
