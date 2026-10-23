import Foundation
import AppKit
import OrbitWidgets
import OrbitCore

/// Exports only bundled, source-controlled native host code. No repository code or
/// JavaScript is executed. Xcode builds continue through the normal trusted catalog.
public enum OrbitAppletExport {
    public static func create(source: String?, destination: URL, bundleID: String, icon: URL? = nil) async throws -> [String: String] {
        guard destination.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: destination.path),
              OrbitSetupState.validPrefix(bundleID) else { throw CodeFailure("Choose a new folder and a unique reverse-DNS bundle ID.") }
        let source = source ?? blank
        let script = try OrbitAppletDefinition.widgetScript(source)
        let fm = FileManager.default
        guard let template = Bundle.module.url(forResource: "AppletHost", withExtension: nil) else { throw CodeFailure("The applet host template is missing.") }
        // Stage beside the destination, so failed exports never leave a partial project.
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".orbit-applet-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let sources = stage.appendingPathComponent("Sources")
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        for folder in ["Runtime", "UI"] { try fm.copyItem(at: template.appendingPathComponent(folder), to: sources.appendingPathComponent(folder)) }
        try fm.copyItem(at: template.appendingPathComponent("HostApp.swift"), to: sources.appendingPathComponent("HostApp.swift"))
        let project = stage.appendingPathComponent("AppletHost.xcodeproj")
        let schemes = project.appendingPathComponent("xcshareddata/xcschemes")
        try fm.createDirectory(at: schemes, withIntermediateDirectories: true)
        try fm.copyItem(at: template.appendingPathComponent("Project/project.pbxproj"), to: project.appendingPathComponent("project.pbxproj"))
        try fm.copyItem(at: template.appendingPathComponent("Project/AppletHost.xcscheme"), to: schemes.appendingPathComponent("AppletHost.xcscheme"))
        try Data(source.utf8).write(to: stage.appendingPathComponent("Applet.js"))
        try fm.createDirectory(at: stage.appendingPathComponent("Config"), withIntermediateDirectories: true)
        try Data("Config/Local.xcconfig\n.DS_Store\n".utf8).write(to: stage.appendingPathComponent(".gitignore"))
        // The display name is data in a plist, never interpolated into build settings.
        let info: [String: Any] = ["CFBundleDisplayName": script.definition.name, "UILaunchScreen": [:], "UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": false]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: stage.appendingPathComponent("Info.plist"))
        let config = """
        PRODUCT_BUNDLE_IDENTIFIER = \(bundleID)
        PRODUCT_NAME = AppletHost
        CODE_SIGN_STYLE = Automatic
        GENERATE_INFOPLIST_FILE = YES
        INFOPLIST_FILE = Info.plist
        MARKETING_VERSION = 1.0
        CURRENT_PROJECT_VERSION = 1
        TARGETED_DEVICE_FAMILY = 1,2
        ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon
        #include? "Local.xcconfig"
        """
        try Data(config.utf8).write(to: stage.appendingPathComponent("Config/App.xcconfig"))
        try await MainActor.run { try writeIcon(icon, to: stage) }
        _ = try await OrbitCommand.run("/usr/bin/git", ["init", "-b", "main"], directory: stage)
        _ = try await OrbitCommand.run("/usr/bin/git", ["add", "."], directory: stage)
        _ = try await OrbitCommand.run("/usr/bin/git", ["-c", "user.name=Orbit", "-c", "user.email=orbit@localhost", "-c", "commit.gpgsign=false", "commit", "-m", "Create JavaScript applet host"], directory: stage)
        guard !fm.fileExists(atPath: destination.path) else { throw CodeFailure("That folder already exists.") }
        try fm.moveItem(at: stage, to: destination)
        return ["project": destination.appendingPathComponent("AppletHost.xcodeproj").path, "scheme": "AppletHost", "branch": "main", "name": script.definition.name, "bundleID": bundleID]
    }
    @MainActor private static func writeIcon(_ url: URL?, to root: URL) throws {
        let image: NSImage
        if let url {
            guard url.path.hasPrefix("/"), (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 10 * 1024 * 1024,
                  let loaded = NSImage(contentsOf: url), loaded.size.width > 0, loaded.size.height > 0 else { throw CodeFailure("Choose a PNG or JPEG icon under 10 MB.") }
            image = loaded
        } else {
            image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { bounds in
                NSColor.systemIndigo.setFill(); bounds.fill()
                let text = "JS" as NSString
                text.draw(at: NSPoint(x: 260, y: 300), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 340), .foregroundColor: NSColor.white]); return true
            }
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CodeFailure("Couldn’t prepare the icon.") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024)); NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CodeFailure("Couldn’t save the icon.") }
        let assets = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try png.write(to: assets.appendingPathComponent("Icon.png"))
        let manifest: [String: Any] = ["images": [["filename": "Icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]], "info": ["author": "xcode", "version": 1]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: assets.appendingPathComponent("Contents.json"))
    }
    public static let blank = #"""
    /* orbit-applet
    {"id":"my-applet","name":"My Applet","domains":[]}
    */
    module.exports = {
      action(ctx, event) { if (event.action === 'tap') ctx.storage.set('count', ctx.storage.get('count', 0) + 1); },
      render(ctx) { return {type:'vstack',spacing:16,children:[
        {type:'text',text:'My Applet',size:32,weight:'bold'},
        {type:'text',text:'Taps: ' + ctx.storage.get('count',0)},
        {type:'button',text:'Tap me',action:'tap'}
      ]}; }
    };
    """#
}
