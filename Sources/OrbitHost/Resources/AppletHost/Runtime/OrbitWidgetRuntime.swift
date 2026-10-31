import Foundation
#if canImport(OrbitDiagnosticsKit)
import OrbitDiagnosticsKit
#endif
import JavaScriptCore

public enum OrbitWidgetRuntime {
    public static func run(script: OrbitWidgetScript, storage: [String: String], family: String, now: Date = Date()) async throws -> OrbitWidgetOutput {
        guard OrbitWidgetStore.families.contains(family) else { throw OrbitWidgetError("Unsupported widget size.") }
        let execution = OrbitWidgetExecution(script: script, storage: storage, family: family, now: now)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { execution.start($0) }
        } onCancel: { execution.stop(OrbitWidgetError("Widget refresh cancelled.")) }
    }
}

/// Public JavaScriptCore APIs cannot interrupt a tight loop. Bound the caller's
/// wait, cancel network work, and quarantine the queue. Two occupied evaluations
/// cap leaked workers until the process exits; an extension also has an OS budget.
final class OrbitWidgetExecution: @unchecked Sendable {
    private static let slots = DispatchSemaphore(value: 2)
    private let queue = DispatchQueue(label: "Orbit.widget.JavaScript", qos: .utility)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OrbitWidgetOutput, Error>?
    private var completed = false
    private var cancelled = false
    private var context: JSContext?
    private var requests: [OrbitWidgetNetwork] = []
    private var requestCount = 0
    private var release: (() -> Void)?
    private let script: OrbitWidgetScript
    private let storage: [String: String]
    private let family: String
    private let now: Date
    private let event: OrbitAppletEvent?
    private let applet: Bool
    private let poll: Bool
    private let notifications: Bool
    private let diagnosticInvocation: String
    init(script: OrbitWidgetScript, storage: [String: String], family: String, now: Date, applet: Bool = false, event: OrbitAppletEvent? = nil, poll: Bool = false, notifications: Bool = false, diagnosticInvocation: String = UUID().uuidString) {
        self.script = script; self.storage = storage; self.family = family; self.now = now; self.applet = applet; self.event = event
        self.poll = poll; self.notifications = notifications; self.diagnosticInvocation = diagnosticInvocation
    }
    func start(_ continuation: CheckedContinuation<OrbitWidgetOutput, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: OrbitWidgetError("Widget refresh cancelled.")); return }
        self.continuation = continuation; lock.unlock()
        queue.async { [self] in
            guard Self.slots.wait(timeout: .now()) == .success else { stop(OrbitWidgetError("Restart Orbit to run more widgets.")); return }
            var released = false
            release = { if !released { released = true; Self.slots.signal() } }
            guard !isCompleted else { release?(); return }
            evaluate()
            if isCompleted { cleanUp() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 18) { [self] in stop(OrbitWidgetError("This widget took too long. Check its JavaScript.")) }
    }
    private var isCompleted: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func stop(_ error: Error) {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(error))
    }
    private func finish(_ result: Result<OrbitWidgetOutput, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
        // Cleanup never enters a VM from a network/deadline thread. A tight loop
        // holds its slot; other evaluations cannot allocate unbounded threads.
        queue.async { [self] in cleanUp() }
    }
    private func cleanUp() {
        requests.forEach { $0.cancel() }; requests.removeAll()
        context = nil; release?(); release = nil
    }
    private func evaluate() {
        guard let context = JSContext() else { stop(OrbitWidgetError("Couldn’t start JavaScript.")); return }
        self.context = context
        context.exceptionHandler = { [weak self] _, value in self?.stop(OrbitWidgetError(value?.toString() ?? "JavaScript failed.")) }
        let fetch: @convention(block) (String, String, JSValue) -> Void = { [weak self] url, options, callback in
            guard let self, !self.isCompleted else { return }
            self.requestCount += 1
            guard self.requestCount <= 8 else { callback.call(withArguments: ["A widget can make up to eight requests per refresh.", NSNull(), NSNull()]); return }
            let network = OrbitWidgetNetwork(definition: self.script.definition) { [weak self] result in
                guard let self else { return }
                self.queue.async { [self] in
                    guard !self.isCompleted else { return }
                    switch result {
                    case .success(let (status, data)): callback.call(withArguments: [NSNull(), status, String(decoding: data, as: UTF8.self)])
                    case .failure(let error): callback.call(withArguments: [error.localizedDescription, NSNull(), NSNull()])
                    }
                }
            }
            do {
                let options = try JSONSerialization.jsonObject(with: Data(options.utf8)) as? [String: Any] ?? [:]
                self.requests.append(network); try network.start(url: url, options: options)
            } catch { callback.call(withArguments: [error.localizedDescription, NSNull(), NSNull()]) }
        }
        let finish: @convention(block) (String) -> Void = { [weak self] json in self?.decode(json) }
        let fail: @convention(block) (String) -> Void = { [weak self] message in self?.stop(OrbitWidgetError(message)) }
        var debugCount = 0
        let debug: @convention(block) (String) -> Void = { [weak self] label in
            guard let self, self.applet, debugCount < 32,
                  OrbitAppDiagnostics.validLabel(label) else { return }
            debugCount += 1
            OrbitAppletDiagnostics.record("breadcrumb", ["applet": self.script.id,
                "revision": OrbitWidgetDefinition.digest(self.script.source), "invocation": self.diagnosticInvocation, "label": label])
        }
        context.setObject(debug, forKeyedSubscript: "_orbitDebug" as NSString)
        context.setObject(fetch, forKeyedSubscript: "_orbitFetch" as NSString)
        context.setObject(finish, forKeyedSubscript: "_orbitFinish" as NSString)
        context.setObject(fail, forKeyedSubscript: "_orbitFail" as NSString)
        var config: [String: Any] = ["family": family, "now": ISO8601DateFormatter().string(from: now), "storage": storage, "poll": poll, "notifications": notifications]
        config["event"] = event.map { ["action": $0.action, "values": $0.values] as [String: Any] } ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { stop(OrbitWidgetError("Couldn’t load widget data.")); return }
        context.evaluateScript("const _orbitConfig = " + String(decoding: data, as: UTF8.self) + ";\n" + Self.bootstrap)
        guard !self.isCompleted else { return }
        context.evaluateScript(script.source, withSourceURL: URL(string: "orbit-widget://" + script.id + ".js"))
        guard !self.isCompleted else { return }
        context.evaluateScript(applet ? Self.invokeApplet : Self.invoke)
    }
    private func decode(_ json: String) {
        guard !self.isCompleted else { return }
        do {
            guard json.utf8.count <= 384 * 1024 else { throw OrbitWidgetError("The widget returned too much data.") }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var result = try decoder.decode(OrbitWidgetOutput.self, from: Data(json.utf8))
            guard (result.notifications?.count ?? 0) <= 1, result.notifications?.isEmpty != false || notifications else { throw OrbitWidgetError("Notifications are only available in an approved poll hook.") }
            for notification in result.notifications ?? [] { try notification.validate() }
            guard !result.entries.isEmpty, result.entries.count <= 64, result.storage.count <= 128,
                  try JSONEncoder().encode(result.storage).count <= 64 * 1024 else { throw OrbitWidgetError("The widget returned too much data.") }
            var previous = Date.distantPast
            for entry in result.entries {
                guard entry.date >= previous, entry.date >= now.addingTimeInterval(-60), entry.date <= now.addingTimeInterval(2 * 86400) else { throw OrbitWidgetError("Widget timeline entries need increasing dates within the next two days.") }
                var count = 0; try entry.view.validate(count: &count, interactive: applet); previous = entry.date
            }
            guard result.entries[0].date <= now.addingTimeInterval(1) else { throw OrbitWidgetError("Start the widget timeline with the current time.") }
            result.updatedAt = now
            finish(.success(result))
        } catch { stop(error) }
    }
    private static let bootstrap = #"""
    const module = { exports: {} };
    const _orbitData = Object.assign(Object.create(null), _orbitConfig.storage);
    const _orbitStorage = Object.freeze({
      get(key, fallback = null) { return Object.hasOwn(_orbitData, String(key)) ? JSON.parse(_orbitData[String(key)]) : fallback; },
      set(key, value) {
        key = String(key);
        if (key.length > 128) throw new Error('Storage keys must be short.');
        const json = JSON.stringify(value);
        if (json === undefined) throw new Error('Save a JSON value.');
        _orbitData[key] = json;
      },
      remove(key) { delete _orbitData[String(key)]; }
    });
    const _orbitNotifications = [];
    const ctx = Object.freeze({family: _orbitConfig.family, now: new Date(_orbitConfig.now), storage: _orbitStorage,
      debug(label) { _orbitDebug(String(label)); },
      notify(notification) {
        if (!_orbitConfig.notifications) throw new Error('Declare notifications:true and call notify only from poll(ctx).');
        if (_orbitNotifications.length) throw new Error('Send at most one notification per poll.');
        _orbitNotifications.push(notification);
      }
    });
    globalThis.fetch = (url, options = {}) => new Promise((resolve, reject) => {
      _orbitFetch(String(url), JSON.stringify(options), (error, status, body) => {
        if (error) { reject(new Error(error)); return; }
        resolve(Object.freeze({status, ok: status >= 200 && status < 300,
          text: async () => body, json: async () => JSON.parse(body)}));
      });
    });
    """#
    private static let invokeApplet = #"""
    (async () => {
      if (_orbitConfig.poll) {
        if (typeof module.exports.poll !== 'function') throw new Error('Export poll(ctx) for scheduled checks.');
        await module.exports.poll(ctx);
        _orbitFinish(JSON.stringify({entries:[{date:ctx.now.toISOString(),view:{type:'text',text:'Checked'}}], storage:_orbitData, notifications:_orbitNotifications, updatedAt:ctx.now.toISOString()}));
        return;
      }
      if (typeof module.exports.render !== 'function') throw new Error('Export render(ctx).');
      if (_orbitConfig.event) {
        if (typeof module.exports.action !== 'function') throw new Error('Export action(ctx, event) for controls.');
        await module.exports.action(ctx, Object.freeze(_orbitConfig.event));
      } else if (module.exports.update) { await module.exports.update(ctx); }
      const view = await module.exports.render(ctx);
      _orbitFinish(JSON.stringify({entries:[{date:ctx.now.toISOString(),view}], storage:_orbitData, updatedAt:ctx.now.toISOString()}));
    })().catch(error => _orbitFail(String(error.message || error)));
    """#
    private static let invoke = #"""
    (async () => {
      if (typeof module.exports.render !== 'function') throw new Error('Export a render(ctx) function.');
      if (module.exports.update) await module.exports.update(ctx);
      const view = await module.exports.render(ctx);
      let entries = [{date: ctx.now.toISOString(), view}];
      if (module.exports.timeline) {
        const future = await module.exports.timeline(ctx);
        if (!Array.isArray(future)) throw new Error('timeline(ctx) must return an array.');
        entries = entries.concat(future);
      }
      _orbitFinish(JSON.stringify({entries, storage: _orbitData, updatedAt: ctx.now.toISOString()}));
    })().catch(error => _orbitFail(String(error.message || error)));
    """#
}
