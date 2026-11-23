---
name: orbit-setup
description: Set up Orbit on a user's Mac and iPhone, including Xcode, their Apple signing account, a pipe provider, both clients and scheduled refreshes.
---

For “install github.com/diaruga777/Orbit” on the user’s Mac, follow the checkout’s AGENTS.md install instructions. Clone once to a durable location or reuse the original checkout. Run `./scripts/install.sh` and continue through downloads, builds and wizard handoff. Let the user respond to Apple and macOS prompts in their native windows. Use the manual Orbit Mac wizard when the user supplies a DMG.

- Use the user's own team, namespace and phone. Prefer a free Personal Team unless they choose an existing paid membership. Keep Mac passwords and signing keys in Apple's tools and phone refresh secrets in Orbit’s device-only Keychain; let the user handle Apple sign-in, license, device trust and permission prompts.
- A Personal Team has seven-day profiles and a three-app-per-device limit; Orbit consumes one slot. Default refreshes to 144 hours. Do not promise unrestricted apps or guaranteed background installation.
- For requested remote setup, explain local Wi-Fi, external Tailscale, an explicit Syncthing relay, and the native dumbpipe/iroh adapter from `docs/pipes.md`; use the user's selected provider. Do not treat Syncthing folder sync as an app installer or assume tailnet reachability makes CoreDevice see a phone.
- Bootstrap writes `~/.orbit/installation.json` for the bundled plugin's MCP launcher. If the checkout moves, rerun bootstrap. Register the stdio MCP using the host's documented configuration; do not overwrite unrelated servers.
- Enable `scripts/install_scheduler.py` only when the user wants ongoing refreshes. Verify the Mac is logged in and has an awake window before the expiry deadline.
- Never install, launch or use WebDriverAgent on a physical phone. Simulator testing and native Xcode/CoreDevice deployment are supported.

Report the next personal action or the verified installed clients. Configure extra targets, pipes and schedules when requested. Report actual build/install results and unresolved human setup steps without inferring physical acceptance from unit tests.

Phone-only renewal is available after the user configures Refresh in Orbit on iPhone: Wi-Fi/LocalDevVPN, an independently trusted phone pairing file, Apple Account/team, a development certificate and cached current builds. A new code revision still needs the Mac. Never request account passwords, private keys or pairing file contents through MCP. Use the widget skill for single-file JavaScript widgets.
