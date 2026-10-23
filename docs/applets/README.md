# JavaScript applets

Applets are little interactive apps inside Orbit. One `.js` file supplies metadata,
native layouts and actions. No web server, HTML, dependencies or AI account is
needed. Public ChatGPT can generate one using **Applets → Add → Copy AI Prompt**
on iPhone or **Applets → Copy AI Prompt** on Mac.

Import from Files, paste on iPhone, or choose **Add JavaScript** on Mac. On iPhone,
**Applets → Add → From Mac** lists queued files. Review the name and exact websites
before approving. Tap an applet to launch it. Imports and updates always ask for
consent; using the same id preserves private state. Deleting it on iPhone removes
its state. Removing a Mac deployment preserves the phone copy.

```js
/* orbit-applet
{"id":"counter","name":"Counter","domains":[]}
*/
module.exports = {
  action(ctx, event) {
    if (event.action === 'add') ctx.storage.set('n', ctx.storage.get('n', 0) + 1);
  },
  render(ctx) {
    return {type:'vstack', spacing:16, children:[
      {type:'text', text:'Count: '+ctx.storage.get('n',0), size:32},
      {type:'button', text:'Add one', action:'add'}
    ]};
  }
};
```

The native root scrolls. Supported nodes are widget `text`, `symbol`, `date`,
`vstack`, `hstack`, `spacer`, plus `divider`, `button`, `textfield`, and `toggle`.
Controls require an `action` string. Inputs require unique `key` strings.
Text fields use `text` for a placeholder and `value` for their current text;
Return submits their action. Toggles use `text`, `isOn` and send string values
`'true'` / `'false'`. Every action receives `event.action` and `event.values`,
containing all current inputs by key. Store changes with `ctx.storage`, then
return the next screen from `render`; storage can hold the navigation state.

Each launch, Reload and action uses a fresh VM. Optional `update(ctx)` runs on
launch/Reload; `action(ctx,event)` runs only for controls, before `render(ctx)`.
`ctx.now` is a Date and `ctx.family` is `'app'`. Async hooks and fetch work as in
[widgets](../widgets/README.md). State commits only after successful rendering.
Errors retain the previous screen. The same source/layout/storage/network limits
and JavaScriptCore infinite-loop limitations apply. Applets have no background
timers or timeline, DOM, filesystem, shell, signing or native bridge.

## Make it its own iPhone app

On Mac, choose **Make Standalone App** for a queued applet, or **Blank Host App**
for a starter. Enter your unique bundle ID, choose a PNG/JPEG icon (or the default
JS icon), and save to a new folder. Orbit creates a self-contained native Xcode
project, including the same runtime and script, and commits the initial revision.
It needs no connection to Orbit after installation. First launch asks for consent.
A new script digest asks again; state survives updates with the same bundle ID.

**Add to Apps** registers it using the selected phone/signing settings. If no
phone is selected, use Add App with the returned project and `AppletHost` scheme.
Build/install and schedules use Orbit's normal flow. Every standalone host uses
another Apple development app slot; free Personal Team limits still apply.

Edit `Applet.js` and commit before building a new revision. Replace
`Assets.xcassets/AppIcon.appiconset/Icon.png` to change the icon, then commit and
rebuild. Keep the bundle ID and signing identity stable. Team overrides belong in
ignored `Config/Local.xcconfig` or Orbit's target settings. Exporting a project is
separate from installing it or preparing an App Store listing.

## CLI / MCP

```sh
bin/orbit applet-prompt
bin/orbit applet-add /absolute/path/counter.js
bin/orbit applets
bin/orbit applet-export /absolute/path/counter.js \
  --destination /absolute/path/Counter \
  --bundle-id com.yourname.counter --icon /absolute/path/icon.png
# Omit the .js path to export a blank starter.
bin/orbit add --project /absolute/path/Counter/AppletHost.xcodeproj \
  --scheme AppletHost --branch main --device YOUR_PHONE --trust
bin/orbit build TARGET_ID
```

MCP tools: `orbit_applet_prompt`, `orbit_applets`, `orbit_applet_add`,
`orbit_applet_remove`, `orbit_applet_export`. Export takes `destination`, `bundleID`,
optional `path` and `iconPath`; it returns `project`, `scheme`, `branch` and `name`.
Use those with `orbit_add_target` / `orbit_build`. MCP queues code for local phone
consent; it cannot remotely approve or launch an imported script on the phone.
