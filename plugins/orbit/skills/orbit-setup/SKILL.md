---
name: orbit-setup
description: Set up Orbit on a user's Mac and iPhone, including Xcode, their Apple signing account, a pipe provider, both clients and scheduled refreshes.
---

Read the current Orbit README at https://github.com/diaruga777/Orbit or the user's checkout. Follow its numbered setup steps. Preserve the user's existing Xcode, signing identities and repository layout.

- Use the user's own team, namespace and phone. Prefer a free Personal Team unless they choose an existing paid membership. Keep passwords and signing keys inside Apple's tools; let the user handle Apple sign-in, license, device trust and permission prompts.
- A Personal Team has seven-day profiles and a three-app-per-device limit; Orbit consumes one slot. Default refreshes to 144 hours. Do not promise unrestricted apps or guaranteed background installation.
- Explain local Wi-Fi, external Tailscale, an explicit Syncthing relay, and the native dumbpipe/iroh adapter from `docs/pipes.md`; use the user's selected provider. Do not treat Syncthing folder sync as an app installer or assume tailnet reachability makes CoreDevice see a phone.
- Clone Orbit to a durable location. Run `scripts/bootstrap.sh`, configure the ignored `Config/Local.xcconfig`, build and install both clients, then pair and compare the phone ID. Use the Mac build script to include the bounded remote-install helper.
- Bootstrap writes `~/.orbit/installation.json` for the bundled plugin's MCP launcher. If the checkout moves, rerun bootstrap. Register the stdio MCP using the host's documented configuration; do not overwrite unrelated servers.
- Enable `scripts/install_scheduler.py` only when the user wants ongoing refreshes. Verify the Mac is logged in and has an awake window before the expiry deadline.
- Never install, launch or use WebDriverAgent on a physical phone. Simulator testing and native Xcode/CoreDevice deployment are supported.

Finish by showing installed client locations, the chosen pipe, target phone and schedule. Report actual build/install results and unresolved human setup steps without inferring physical acceptance from unit tests.
