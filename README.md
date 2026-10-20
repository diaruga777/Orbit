# Orbit

**Build an iOS app. Keep it on your phone.**

Orbit is an open source iPhone/iPad source editor and Mac build companion. Add a local Xcode project or a GitHub repository, choose your phone, and build immediately or on a schedule. Your Mac runs Xcode and signs the app with **your** Apple account. Source, Apple credentials, pairing records and signing keys stay on your devices.

You need a Mac, an iPhone, and either a coding agent subscription/credits or enough development experience to configure the tools yourself. Orbit includes an MCP and setup/deploy skills, so an agent can follow this README end to end. Orbit does not require an AI provider, subscription, hosted backend or paid Apple membership.

> Free Apple accounts are supported. Apple limits Personal Teams to three installed development apps per device, three registered devices and ten App IDs; profiles expire after seven days. Orbit itself uses one app slot. Orbit defaults to **every six days**, leaving a day for recovery. This works for compatible apps within Apple's limits—not every app or entitlement. A refresh still needs an awake, logged-in Mac and a reachable, trusted phone. [Apple account limits](https://developer.apple.com/help/account/basics/about-your-developer-account)

## Quick path with an agent

Clone this repository and ask your agent:

> Read Orbit's README and AGENTS.md. Help me install Xcode and Orbit, sign in to my own Apple Personal Team, connect my phone, choose a pipe, then add my app and refresh it every six days. Keep account credentials in Xcode. Ask me to perform Apple sign-in and trust prompts myself.

Install the bundled plugin or [MCP](#connect-your-agent) once the Mac app is running. An agent can discover phones, inspect repositories, register an app it just created, start a build, read its log, and change its schedule.

## 1. Prepare your Mac and Apple account

1. Install the full [Xcode application](https://developer.apple.com/xcode/) supported by your Mac and iPhone OS. Orbit's iOS client targets **iOS 26+**; its Mac client targets **macOS 15+**. Use Xcode 26.2 or newer for Orbit. The apps you add can support older iOS versions.
2. Open Xcode once, accept its license and install requested iOS platform components. In Xcode → Settings → Locations, select that Xcode for Command Line Tools. `xcode-select -p` should point inside the full Xcode app, not just `/Library/Developer/CommandLineTools`.
3. In Xcode → Settings → Accounts, add your Apple Account. Create an account through Apple's sign-in flow if you need one. A free account appears as **Personal Team**. If you already pay for the [Apple Developer Program](https://developer.apple.com/programs/enroll/), choose that team instead. Do not enroll in the paid program just to try Orbit.
4. Connect your iPhone by USB, unlock it, choose Trust on both devices, and enable [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device). In Xcode's Devices and Simulators window, finish pairing and enable Connect via network. First installation and any Apple trust prompts require your attention.
5. If needed, run a small app once from Xcode with your selected team. Resolve account agreements, signing and device support in Xcode before automating them. Orbit uses this existing setup; it never asks for your Apple password or exports a signing key.

Install [Homebrew](https://brew.sh/) if you use it, then:

```sh
brew install go xcodegen python
# Optional: useful for private GitHub repositories and development.
brew install gh
```

Git and Swift come with Xcode. Go builds Orbit's small transport and Apple installation helper from source. Python runs the CLI/MCP. XcodeGen generates the app project. You do not need Rust for the pinned iroh package; a source-build option is documented upstream.

## 2. Build Orbit with your own identifiers

```sh
git clone https://github.com/diaruga777/Orbit.git
cd Orbit
./scripts/bootstrap.sh
```

Edit the ignored `Config/Local.xcconfig` created by bootstrap:

```xcconfig
ORBIT_BUNDLE_PREFIX = com.yourname.orbit
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Use your own unique reverse-DNS prefix and your team identifier from Xcode. The resulting apps are `com.yourname.orbit.ios` and `com.yourname.orbit.mac`. Neither app requires App Groups, iCloud, shared keychain groups or Luna's premium system. No developer account or team ID is included in the repository. If building for Simulator first, leave the team unset.

Open `Orbit.xcodeproj`. Select the **Orbit** scheme and your phone, then Run. Xcode uses automatic development signing. The phone may ask you to trust your development certificate in Settings → General → VPN & Device Management. Keep the app installed; reinstalling from scratch can discard its local drafts and pairing identity.

To build the complete Mac app, including its optional remote-install helper:

```sh
security find-identity -v -p codesigning
ORBIT_MAC_SIGNING_IDENTITY='EXACT APPLE DEVELOPMENT CERTIFICATE NAME OR SHA-1' \
  ./scripts/build_and_run.sh
```

The script builds, signs and installs `~/Applications/Orbit Mac.app`, then opens it. Keep the same certificate, bundle ID and installed path between updates so macOS file-access permissions persist. `--build-only` produces a separate `dist/Orbit Mac.app` for inspection and never replaces the installed app. Xcode's **OrbitMac** scheme also builds the client; use the script for the bundled remote installer.

Allow Local Network access on both devices. Grant the Mac app access to source folders when macOS asks. If projects live under Desktop/Documents or other protected locations, access depends on macOS permissions. Move projects to a normal development folder if that is more convenient.

## 3. Choose a pipe and pair

Orbit owns application-level trust independently of the pipe. A route is never proof of identity. Pairing pins a certificate identity for TCP/Syncthing or an iroh endpoint key for dumbpipe; the Mac explicitly approves the phone. There is no automatic switch to a public relay when a local route fails.

| Choice | Setup | What it does |
| --- | --- | --- |
| Local Wi-Fi | Both devices on your LAN; no extra software | Direct encrypted connection, with no intermediary or external discovery |
| Tailscale | Install and sign in to the separate client on both devices | Direct/relayed networking according to your tailnet policy; Orbit still authenticates its own connection |
| Syncthing relay | Provide an explicit `strelaysrv` URL | Carries Orbit's end-to-end authenticated streams; this is the Syncthing relay protocol, not a synced-folder job queue |
| dumbpipe / iroh | Choose the built-in adapter | Uses iroh's authenticated QUIC streams, discovery and N0 relays as needed; no desktop CLI on iPhone |

Detailed commands, private relay setup and troubleshooting: **[Pipes](docs/pipes.md)**.

With Orbit Mac running, configure your choice using the [CLI](#connect-your-agent):

```sh
bin/orbit configure --provider local
# Or one of:
bin/orbit configure --provider tailscale --address tcp://YOUR-MAC.YOUR-TAILNET.ts.net:49210
bin/orbit configure --provider syncthing --relay 'relay://YOUR-RELAY:22067/?id=RELAY_CERTIFICATE_ID'
bin/orbit configure --provider dumbpipe
```

Restart Orbit Mac after changing its provider. In its window, click **Connect a Phone**, copy the pairing code, and paste it into the iPhone app's **Mac → Connect a Mac**. Compare the phone ID displayed on both devices before approving on the Mac. The pairing window lasts five minutes. Syncthing relay enrollment starts with direct pairing; after approval copy the relay route as described in the pipe guide.

For native USB/Wi-Fi deployment, you can use only the Mac client and CLI/MCP and skip installing the Orbit iOS client, leaving all three free-account app slots available for your own apps. The iOS client adds source editing, remote control and phone-side forwarding.

You can build/install through Xcode's native USB or Wi-Fi connection without an iPhone control app being awake. Remote-control reachability and Apple installation reachability are different: putting both devices on a tailnet alone does not make CoreDevice discover the phone. Orbit includes a separate bounded forwarding path for remote installations; see [remote installation limits](docs/architecture.md#remote-installation).

## 4. Add an app

Start with a project you trust. Xcode projects, package plugins and build phases can execute code on your Mac. A GitHub compatibility check finds an Xcode project before cloning; it is not a security review or a promise that an arbitrary repository will compile.

In either client, use **Apps / Add App**. You can enter a local `.xcodeproj` or `.xcworkspace`, or browse GitHub, select a repository, and inspect its Xcode project paths. Choose a runnable iOS app scheme, the phone, branch and signing team. Shared schemes make setup reproducible. Library-only Swift packages, Android/web projects and repositories requiring unrun project generators do not qualify until they contain a working Xcode app project.

The CLI and MCP expose the same catalog:

```sh
bin/orbit devices
bin/orbit add --name 'My App' \
  --project /absolute/path/MyApp/MyApp.xcodeproj --scheme MyApp \
  --device YOUR_PHONE_UDID --team YOUR_TEAM_ID --branch main \
  --account free --enable --interval-hours 144 --trust
bin/orbit targets
bin/orbit build TARGET_ID
bin/orbit job JOB_ID
```

`--trust` records your decision to run that source. Orbit checks the selected scheme on your Mac before registration. It rejects WebDriverAgent app schemes. **Orbit never installs or uses WebDriverAgent on your phone.**

Keep your app's bundle identifiers unique and configure its entitlements for your team in the source project. An Orbit target's `--team` is an optional build-setting override, applied to the whole build so extensions use the same team. Orbit does not globally rewrite an application's bundle ID or silently remove unsupported capabilities. Free Personal Teams cannot sign capabilities such as App Groups, iCloud or push notifications; choose another app or adapt its source, or use a paid team when needed. [Apple capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios)

**Commit the source you want to install.** Orbit builds a detached Git worktree from the selected branch; unsaved/uncommitted edits in the source editor or an agent's working tree are not part of that revision. Local targets use that local branch as-is. Targets cloned by Orbit fetch the chosen GitHub branch before each fresh build without changing the checkout's active branch.

To use GitHub directly:

```sh
bin/orbit github-search 'habit tracker language:Swift'
bin/orbit github-inspect OWNER/REPOSITORY
bin/orbit github-add OWNER/REPOSITORY \
  --project Relative/Example.xcodeproj --scheme Example \
  --device YOUR_PHONE_UDID --team YOUR_TEAM_ID --account free \
  --enable --interval-hours 144 --trust
```

Public search works without a GitHub account, subject to GitHub's API rate limits. For private repositories, launch Orbit Mac with your own `GH_TOKEN` environment variable, and configure Git's credential helper or GitHub CLI on the Mac for cloning. The token is never sent to iPhone, stored in a target or returned by the MCP. API read access and Git clone access must both work.

## 5. Enable scheduled refreshes

```sh
python3 scripts/install_scheduler.py
bin/orbit schedule TARGET_ID --enable --interval-hours 144
```

The per-user launch agent starts the installed Orbit Mac app at login. Orbit checks due targets every minute, catches up after missed time, keeps job state on disk, serializes device installs and retains ready artifacts while waiting for the phone. It runs while you are logged in and the Mac is awake; launchd cannot build on a sleeping or powered-off Mac. Arrange a recurring awake window in your own macOS power settings, leave the phone reachable, and check the last **confirmed installation**, not merely the last compilation.

Scheduled installs do not launch or terminate the installed app. A manual `bin/orbit build TARGET_ID --launch` requests launch too. Orbit can refresh its own iOS app through an independent native Apple connection; it refuses to replace the app carrying an active remote forwarding session.

Personal Team targets default to six days and reject intervals longer than 144 hours. Before compiling, Orbit temporarily sets aside only matching automatic-signing cached profiles that expire too soon, asks Xcode to update provisioning, and restores the cache afterward or on restart. It verifies the resulting app **and extensions** have enough profile lifetime for the interval plus twelve hours before installing. If Apple/Xcode cannot renew signing, the build reports a signing problem instead of declaring the refresh complete. Paid-account targets can use `--account paid` and their own interval.

To pause or remove:

```sh
bin/orbit schedule TARGET_ID --disable
bin/orbit remove TARGET_ID
python3 scripts/install_scheduler.py --remove
```

Removing a target keeps its source repository and the app already installed on your phone. To revoke phone access, use `bin/orbit forget` on the Mac. To remove Orbit entirely, also delete its app bundles and `~/.orbit` after saving any drafts, targets and logs you want to keep.

## Connect your agent

The MCP uses standard JSON-RPC over stdio and Python's standard library. It talks to the running Mac app through an owner-only Unix socket. It requires no agent SDK or AI API key. Agent subscriptions/credits are your choice and separate from Orbit.

```sh
mkdir -p ~/.local/bin
ln -s "$PWD/bin/orbit" ~/.local/bin/orbit
# Add ~/.local/bin to PATH if it is not there already.
codex mcp add orbit -- "$PWD/bin/orbit" mcp
```

For Cursor, VS Code/Copilot or other stdio MCP hosts, add this server using an **absolute** path:

```json
{
  "mcpServers": {
    "orbit": { "command": "/absolute/path/to/Orbit/bin/orbit", "args": ["mcp"] }
  }
}
```

**[Agent integrations](docs/agents.md)** covers Codex and Cursor plugin packages, local installation, optional marketplace submission, Claude Code and portable skills. Installing the plugin can guide setup and register the MCP; it cannot accept Apple's licenses, sign in to Apple, grant macOS permissions or trust your phone for you.

Useful agent request:

> Add the iOS app you just created to Orbit for my selected phone, use my existing signing setup, commit the intended source, build and install it now, then refresh it every six days. Inspect any new GitHub dependency before running it.

## Develop and contribute

```sh
./scripts/bootstrap.sh
swift test
python3 -m unittest discover -s Tests/Python -v
go -C Transport/Go test -race ./...
go -C tools/apple-adapter test -race ./...
xcodebuild -project Orbit.xcodeproj -scheme Orbit \
  -destination 'generic/platform=iOS Simulator' build
./scripts/build_and_run.sh --build-only
```

The transport XCFramework is generated from this repository's Go sources and ignored by Git. Dependencies are pinned in `Package.resolved` and Go module files. The optional synthetic private-relay test is documented in [Testing](docs/testing.md). CI builds both clients and runs unit tests; it does not contact a real phone, sign into Apple or publish an app.

[Architecture and limits](docs/architecture.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

Orbit was extracted from Luna Code. It has independent app identities and storage; it does not read Luna's App Group or migrate Luna's Apple credentials. MIT licensed; third-party components retain their own licenses.
