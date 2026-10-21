---
name: orbit-widgets
description: Write or deploy single-file JavaScript Home Screen and Lock Screen widgets for Orbit, including network data, local key-value storage and departure timelines.
---

Read [the widget API](references/widget-api.md) before writing a script. Produce one `.js` file with the literal metadata header and CommonJS hooks; no build project or dependencies are needed.

Use a documented public API. Ask for missing station IDs or required API access instead of inventing endpoints or credentials. Keep secrets out of generated source. Prefer fetching multiple future departures and generating timeline entries rather than polling each minute. iOS controls refresh timing.

Use `orbit_widget_add` with the absolute Mac file path to queue a script. The user opens Widgets → Add → From Mac on iPhone and approves the code and domains. Preserve the ID when updating a widget so its data and configuration survive. A queued deployment is not proof of phone activation. For phone-only creation, give the user the `.js` file to import or paste into Orbit. No Mac build is needed.
