# Orbit widget authoring contract

Write one self-contained .js file for an Orbit widget. My widget should: [describe what you want, your station/location, and the public API or data source].

Start the file with this literal metadata comment (valid JSON, no trailing commas):
/* orbit-widget
{"id":"my-widget","name":"My Widget","domains":["api.example.com"],"refreshMinutes":30}
*/
Use a stable lowercase id (letters, numbers, dots, hyphens). domains lists exact HTTPS hosts, no wildcards or IP addresses. Only list hosts the script actually uses. refreshMinutes is 15–1440; iOS chooses the actual refresh time. No imports, libraries, browser/DOM, timers, eval, require, or native APIs. JavaScriptCore supports modern JavaScript and async/await.

Export CommonJS hooks:
module.exports = {
  async update(ctx) { /* fetch data, then ctx.storage.set('data', JSON value) */ },
  render(ctx) { return {type:'text', text:'Hello', size:20, weight:'bold'}; },
  timeline(ctx) { return []; } // optional future entries: [{date:ISO8601, view:layout}]
};

ctx = { family, now: Date, storage }. family is small/medium/large/circular/rectangular/inline.
storage.get(key, fallback=null), .set(key, JSON value), .remove(key). Storage is private to this widget, survives refresh, and is limited to 64 KiB and 128 keys. update runs before render on each timeline request. Keep render quick and do all network work in update. Storage is committed only after successful execution. No secrets in the source.

fetch('https://approved.host/path', {method:'GET', headers:{...}}) returns a Promise of {ok,status,json:async function,text:async function}. POST and small string bodies are supported too. No cookie jar. Check response.ok. At most eight requests, 1 MiB per response, 10-second request timeout; the entire refresh has an 18-second deadline. Cross-domain redirects are rejected. Use a public documented API; don’t invent an endpoint or credentials. Ask me for missing station IDs or API details. Do not scrape a JavaScript-only website.

Layout nodes (JSON objects only):
- {type:'text',text:'...',size:16,weight:'regular',color:'primary'}
- {type:'symbol',symbol:'tram.fill',size:24,color:'accent'} (SF Symbols)
- {type:'vstack'|'hstack',spacing:8,children:[nodes...]}
- {type:'spacer',spacing:0}
- {type:'date',date:ISO8601,size:16} (native relative time)
Colors: primary/secondary/accent/red/orange/green/blue/purple. Weights: regular/medium/semibold/bold. Font sizes 8–72, spacing 0–40. At most 120 nodes, depth 8. Fit the selected family; inline/circular are tiny. No HTML, CSS, image URLs, arbitrary SwiftUI, or interactivity. Include an empty-data layout.

render supplies the current entry. Optional timeline returns up to 63 additional entries with strictly increasing ISO8601 dates after ctx.now within 48 hours. Fetch several departures in update, then build future layouts at departure times so the display changes between network refreshes. Preserve an indication of when the data was fetched. Never promise precise scheduled network refreshes. Return only the .js file.
