# JavaScript widgets

Orbit ships one native WidgetKit extension. Each imported JavaScript file is a
widget definition in that host, not a newly compiled iOS extension. Script updates
do not rebuild or reinstall Orbit. Small, medium and large Home Screen widgets,
and inline, circular and rectangular Lock Screen widgets are supported.

Add a file from Files, paste JavaScript in Widgets, or use **Copy AI Prompt**.
The prompt is provider-independent; public ChatGPT or another coding assistant
can return the complete single file. [The departure demo](examples/departures-demo.js)
works offline and deliberately identifies its sample data. A live transit widget
needs a real documented data source, station ID, and any required API credentials.

To deploy from Mac, choose Widgets → Add JavaScript or run:

```sh
bin/orbit widget-add /absolute/path/trains.js
bin/orbit widgets
```

The MCP equivalents are `orbit_widget_add`, `orbit_widgets` and
`orbit_widget_remove`. On iPhone choose Widgets → Add → From Mac, then review the
script and its domains. Existing widget IDs update in place, preserving K-V data;
all cached layouts are invalidated. Mac removal preserves the independent phone
copy. Every import/update needs phone-side approval before code executes.

The file begins with a literal JSON metadata comment, parsed without evaluation:

```js
/* orbit-widget
{"id":"next-train","name":"Next Train","domains":["api.example.com"],"refreshMinutes":30}
*/
module.exports = {
  async update(ctx) { /* fetch and save JSON with ctx.storage.set */ },
  render(ctx) { return {type:'text',text:'No departures yet'}; },
  timeline(ctx) { return []; } // optional future {date: ISO8601, view: node} entries
};
```

`ctx` contains `family`, `now` (Date) and per-widget `storage` with `get`, `set`,
and `remove`. Fetch returns `{ok,status,json(),text()}` with Promise-based body
readers. Only HTTPS GET/POST is exposed; hosts must exactly match approved domains.
Requests have no shared cookie/credential store and cannot redirect across hosts.
The runtime has no native filesystem, signing, Keychain, shell, DOM or module API.
Storage is JSON, limited to 64 KiB and 128 keys, and commits only after a complete
successful evaluation. App/extension processes may update concurrently; K-V writes
use last-completed-refresh semantics, not database transactions.

Native layout nodes are text, SF Symbol, horizontal/vertical stack, spacer and
relative date. The complete generation prompt is maintained in
`Sources/OrbitWidgets/OrbitWidgetPrompt.swift` and mirrored in the bundled agent
skill reference. Maximum source size is 128 KiB; layouts are bounded to 120 nodes
and eight levels. Timelines contain a current entry plus up to 63 ordered future
entries within 48 hours. A refresh permits at most eight requests, 1 MiB each,
with an 18-second overall caller deadline.

The requested interval is 15–1440 minutes. WidgetKit controls actual background
refreshes; exact polling is not guaranteed. Fetch multiple departures at once and
supply timeline entries at departure times. On network/script failure the last
good display remains, marked stale. Previewing the same family respects the
stored data on later WidgetKit reads until the interval is due. Selecting another
family may need its own render and update. Small Lock Screen views should use
one line or a symbol.

Scripts and state share the containing app’s explicitly configured Keychain
access group, with non-synchronizing ThisDeviceOnly items; no paid App Group or
iCloud container is requested. Sharing and renewal still need physical acceptance
with the intended free/paid signing profile. Native widget display stops when its
containing development app/extension expires.

JavaScriptCore’s public APIs cannot interrupt a tight infinite loop. The deadline
bounds waiting and late results never commit, but cannot stop that code. Timed-out
queues are quarantined and a two-evaluation cap prevents unbounded worker growth;
a wedged process needs relaunch. Only run scripts you trust. No private JSC watchdog
API is used. These restrictions do not make arbitrary JavaScript memory-safe or
prevent a script exhausting its process memory.
