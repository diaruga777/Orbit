import Foundation
#if canImport(OrbitDiagnosticsKit)
import OrbitDiagnosticsKit
#endif

/// A separate, non-evaluated manifest keeps widgets and interactive applets distinct.
public struct OrbitAppletDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var domains: [String]
    public var pollHours: Double?
    public var notifications: Bool?
    public var pollingConsent: String? {
        guard let pollHours else { return nil }
        return "Checks about every \(pollHours.formatted()) hours. iOS chooses background times." + ((notifications ?? false) ? " Can send notifications." : "")
    }
    public static func parse(_ source: String) throws -> Self {
        let prefix = "/* orbit-applet\n"
        guard source.utf8.count <= OrbitWidgetDefinition.maximumSourceBytes, source.hasPrefix(prefix),
              let end = source.range(of: "*/") else { throw OrbitWidgetError("Choose JavaScript with an Orbit applet header.") }
        let json = String(source[source.index(source.startIndex, offsetBy: prefix.count)..<end.lowerBound])
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
        catch { throw OrbitWidgetError("The applet header needs an id, name, and domains.") }
        _ = try value.widgetDefinition()
        guard value.pollHours.map({ $0.isFinite && (0.25...8760).contains($0) }) ?? true,
              value.notifications != true || value.pollHours != nil else {
            throw OrbitWidgetError("Use pollHours from 0.25 to 8760. Notifications need polling.")
        }
        return value
    }
    private func widgetDefinition() throws -> OrbitWidgetDefinition {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "name": name, "domains": domains, "refreshMinutes": 30])
        return try .parse("/* orbit-widget\n" + String(decoding: data, as: UTF8.self) + "\n*/")
    }
    public static func widgetScript(_ source: String) throws -> OrbitWidgetScript {
        let definition = try parse(source)
        return OrbitWidgetScript(definition: try definition.widgetDefinition(), source: source)
    }
}

public struct OrbitAppletEvent: Sendable {
    public let action: String
    public let values: [String: String]
    public init(action: String, values: [String: String] = [:]) { self.action = action; self.values = values }
}

public enum OrbitAppletRuntime {
    /// Each launch/action gets a fresh VM; durable state belongs in ctx.storage.
    public static func run(script: OrbitWidgetScript, storage: [String: String], event: OrbitAppletEvent? = nil, poll: Bool = false, now: Date = Date()) async throws -> OrbitWidgetOutput {
        let checked = try OrbitAppletDefinition.widgetScript(script.source)
        let definition = try OrbitAppletDefinition.parse(script.source)
        guard !poll || (definition.pollHours != nil && event == nil) else { throw OrbitWidgetError("This applet has no polling schedule.") }
        guard event.map({ !$0.action.isEmpty && $0.action.count <= 128 && $0.values.count <= 120 && $0.values.allSatisfy { $0.key.count <= 128 && $0.value.count <= 2000 } }) ?? true else {
            throw OrbitWidgetError("This applet received too much input.")
        }
        let invocation = UUID().uuidString
        let execution = OrbitWidgetExecution(script: checked, storage: storage, family: "app", now: now, applet: true, event: event, poll: poll, notifications: poll && definition.notifications == true, diagnosticInvocation: invocation)
        let fields = ["applet": script.id, "revision": OrbitWidgetDefinition.digest(script.source),
                      "invocation": invocation, "hook": poll ? "poll" : (event == nil ? "update" : "action"),
                      "action": event?.action ?? "open"]
        OrbitAppletDiagnostics.record("started", fields)
        do {
            let output = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { execution.start($0) }
            } onCancel: { execution.stop(OrbitWidgetError("Applet closed.")) }
            OrbitAppletDiagnostics.record("completed", fields)
            return output
        } catch {
            // JavaScript errors can interpolate private input; omit their message.
            OrbitAppletDiagnostics.record("failed", fields)
            throw error
        }
    }
}

public enum OrbitAppletPrompt {
    public static let text = #"""
    Write a complete single-file JavaScript applet for Orbit on iPhone. Return only the .js source, without Markdown fences. No libraries, HTML, DOM, require, timers, native APIs or AI service dependency.
    Start with this literal JSON comment (choose a unique lowercase id and a friendly name):
    /* orbit-applet
    {"id":"my-applet","name":"My Applet","domains":[]}
    */
    module.exports = {
      async update(ctx) { /* optional: runs on launch and Reload */ },
      async action(ctx, event) { /* event.action and event.values (all string inputs); save state */ },
      render(ctx) { return {type:'vstack',children:[{type:'text',text:'Hello'},{type:'button',text:'Tap',action:'tap'}]}; }
    };
    Every invocation uses a fresh JavaScript VM. Persist JSON with ctx.storage.get(key, fallback), set(key,value), remove(key). State commits only after successful output. ctx.now is a Date, ctx.family is 'app'. Use storage for navigation/screens. action runs before render; update does not run on actions. No timers or timeline.
    For internet monitoring add optional header fields "pollHours":6,"notifications":true (pollHours 0.25–8760 hours, fractional allowed). Export async poll(ctx): fetch an exact granted HTTPS source, check response.ok, parse response.json() or response.text() with JavaScript (no DOMParser), compare the parsed result with private storage, save it, and optionally call ctx.notify({id:'stable-event-id',title:'Short title',body:'What changed'}). At most one notification per poll; title <=100 chars, body <=2000, id 1–128. Keep event IDs stable to avoid repeats (last 64 delivered IDs remembered); usually store a silent baseline on the first check. notify is only available from poll with notifications:true. poll runs separately from update/action/render; render reads saved data. A failed poll commits no script state or notifications. Notification permission is requested on the phone; denial still allows checks. Checks run when due while Orbit is active and during iOS-granted background refresh. pollHours is a minimum requested interval, never an exact guarantee; iOS can delay or prevent checks when closed, force-quit or background refresh is disabled. No Mac or server is required. Failed checks retry after at least 15 minutes. Imported/updated polling and notification permissions require consent. The same API works in exported standalone apps.
    Debugging is automatic: Orbit records ordered applet action IDs, hook starts/results and revision/session metadata for Mac agents. Use stable descriptive action IDs (open-settings, save-item), never user values in IDs. Call ctx.debug("screen.settings") or ctx.debug("save.started") for navigation and important branches; use fixed developer labels only. Do not pass inputs, fetched content, storage, credentials or personal data. Do not add a logging toggle, export step or AI dependency.
    Native node types: text {text}, symbol {symbol: SF Symbol name}, vstack/hstack {children,spacing}, spacer, date {date:ISO8601}, divider, button {text,action}, textfield {text:placeholder,key,value,action}, toggle {text,key,isOn,action}. Text fields submit on Return; toggles send 'true'/'false'. All controls send all current inputs in event.values keyed by key. Use unique input keys. Controls require a nonempty action. Button text is its accessible label. No nested children in controls. Root scrolls vertically. Nodes support size 8–72, weight regular/medium/semibold/bold, color primary/secondary/accent/red/orange/green/blue/purple, spacing 0–40. Max 120 nodes, 8 levels, text/input 2000 characters.
    fetch(url,{method:'GET'|'POST',headers,body}) returns {ok,status,json:async(),text:async()}. Only HTTPS with exact hosts in manifest domains, no credentials in URLs, no cross-host redirects. No shared cookies or credentials. Eight requests per invocation, 1 MiB responses, 16 KiB request bodies, 18 second deadline. Storage: 128 keys, 64 KiB total. Source:128 KiB. Import/update always needs phone consent. Only use real documented APIs; clearly label sample data. Ask for missing requirements before producing the file.
    """#
}
