# Orbit

**Build apps for your phone and Mac.**

Orbit is an open source iPhone/iPad source editor and Mac build companion for iOS and macOS apps. Add a local Xcode project or a GitHub repository, choose your phone, and build immediately or on a schedule. Your Mac runs Xcode and signs the app with **your** Apple account. Source, Apple credentials, pairing records and signing keys stay on your devices. Orbit also hosts single-file JavaScript applets and Home Screen / Lock Screen widgets.

Both apps share a white iPhone-and-MacBook silhouette icon on black. Artwork and export details
are in [app icons](docs/design/app-icons.md). The Mac menu bar uses a flat,
monochrome version of the same laptop, phone and orbit.

You need a Mac, an iPhone, and either a coding agent subscription/credits or enough development experience to configure the tools yourself. Orbit includes an MCP and setup/deploy skills, so an agent can follow this README end to end. Orbit does not require an AI provider, subscription, hosted backend or paid Apple membership.

> Free Apple accounts are supported. Apple limits Personal Teams to three installed development apps per device, three registered devices and ten App IDs; profiles expire after seven days. Orbit itself uses one app slot. Orbit defaults to **every six days**, leaving a day for recovery. This works for compatible apps within Apple's limits—not every app or entitlement. A new build needs an awake, logged-in Mac and a reachable, trusted phone. Once cached on iPhone, the same installed build can be renewed without the Mac through **More → Phone-only refresh**. [Apple account limits](https://developer.apple.com/help/account/basics/about-your-developer-account)

## Website

The landing page lives in [`website/`](website/). It is a dependency-free static
site prepared for GitHub Pages at `https://diaruga777.github.io/Orbit/`. See
[website hosting](docs/website.md) for preview, deployment and release downloads.

## Install from a DMG

Open **Orbit Mac** from the DMG to launch the resumable setup wizard. It installs
itself, installs Xcode and missing dependencies, asks for a projects folder
(default **~/Desktop/Orbit**), detects your Xcode signing account, and installs
Orbit on your selected iPhone. Keep both devices on the same Wi-Fi for setup.
There is no AI integrations step, Team ID field or bundle ID field.

The tools page uses [xcodes](https://github.com/XcodesOrg/xcodes), installed via
Homebrew (which Orbit installs if needed). Orbit selects the newest stable Xcode
compatible with your macOS from the same release feed used by xcodes. Apple sign-in, verification and Mac
password prompts appear in a private interactive installer inside Orbit; replies
and transcripts are never saved in setup/build logs. Xcodes owns its download
credentials in Keychain. Add your signing account in Xcode’s own Accounts screen;
Orbit detects its signing teams when you return, even before a development
certificate exists. If more than one team is available, choose its
name. Orbit generates and saves its phone app identifiers once, preserving them
on resume and updates. Apple trust, Developer Mode, account and license prompts
still need your attention.

Orbit uses the selected full Xcode for phone discovery and builds. If Command
Line Tools or a removed Xcode is selected, it uses the open or installed Xcode
without changing your Mac’s system selection.

Phone selection, Developer Mode guidance, build/install and connection code share
one page. Installation is complete only after installed-revision readback;
pairing can also be finished later. On iPhone, **More → Phone-only refresh**
and **More → Remote builds** hold the optional setup. Each row is badged until its own setup is complete; More is
badged while either needs setup. Remote setup uses the saved connection, so a
disconnected Mac does not reset it. Orbit Mac keeps its **Take Orbit with you**
banner. Local Wi-Fi is the default; enabling remote connections is an explicit later choice.

The DMG contains the committed phone project, native archives and local agent
launcher. End users do not need to clone this repository or install Go/XcodeGen.
Xcode resolves the pinned Swift package sources on first build. See
[DMG packaging](docs/distribution.md) for producing a release. A development-signed
review DMG is not a publicly notarized download.

## JavaScript applets, widgets and phone refresh

**Applets → Add → Copy AI Prompt** gives public ChatGPT or another assistant the
complete single-file applet API. Drop its `.js` file anywhere in the Mac window,
use **Add JavaScript**, or save it in a watched folder. Orbit reads the header to
choose Applets or Widgets. Both tabs show their folder and let you change it;
defaults are **Applets** and **Widgets** inside your setup folder. Folder additions
and edits appear automatically. The paired iPhone receives them while Orbit is
open and connected, with a badge for files waiting for review. Approve each new
file or update and its websites before it runs. On iPhone you can also use
**Add → Import JavaScript**, paste code, or share a `.js` file to Orbit. File
imports choose the right tab from the content. Tap an approved applet to open it.
On Mac, **Applets → Make Standalone App** (or **Blank Host App**) creates a
committed Xcode project with an icon selector. Add that project to Apps to build
and install it with your own signing setup. MCP supports the same workflow.
Applets can also check an approved HTTPS source every few hours, parse results
and send local notifications. Set `pollHours`, export `poll(ctx)`, and compare
results in private storage. iOS chooses background check times; overdue checks
also run while Orbit is open. This works in standalone hosts too.
See [applets](docs/applets/README.md).

**Widgets → Add → Copy AI Prompt** gives you a prompt for public ChatGPT or another
assistant. Import its `.js` file using the same flows, review the allowed websites, preview it,
and select it in an Orbit Home Screen or Lock Screen widget. The Mac and MCP can
queue files too. Hooks render native layouts, fetch network data, store private
JSON values, and supply future timeline entries. iOS controls actual refresh times;
exact polling is not guaranteed. See [widgets](docs/widgets/README.md).

In Apps, tap an app and choose **Cache build**, or cache Orbit itself in
More → Phone-only refresh. Sign in with your Apple Account (no server address needed), then set up the team, certificate, pairing file and
LocalDevVPN once; then renew cached installed revisions without the Mac. The default sign-in helper uses Mac ADI with matching client settings; an old saved helper can be reset by clearing Advanced’s server field. Export the pairing file in Orbit Mac after your iPhone has trusted that Mac; iOS sign-in and LocalDevVPN aren’t needed for the export. New code
still needs a Mac build. See [phone refresh](docs/local-refresh.md).

While phone-only refresh setup is unfinished, Orbit asks to allow notifications
and keeps one reminder for 24 hours before the earliest known installed app
expires. Tapping it opens **More → Phone-only refresh**.
Orbit uses the signed app/extension profiles’ actual expiry (including paid-team
builds); without that metadata it assumes seven days after confirmed installation.
Open Orbit after Mac installs so it can sync the latest dates. The scheduled
notification then works without the Mac or Orbit running. Notification permission
and iOS delivery settings still apply.

To identify a running Mac copy, choose **Orbit Mac → About Orbit Mac**. Its bundle ID is selectable for copying.

## Client logs

Orbit keeps private rotating action logs on both devices. They include screen
changes, taps/clicks, requests, build/job transitions and errors. Text-field
contents, source files, RPC bodies, Apple sessions and installer transcripts are
excluded; error metadata is bounded and redacted.

While Orbit is open, iPhone logs automatically sync to its paired Mac every ten
seconds. Offline entries stay on the phone and resume from the last acknowledged
event. Each journal keeps up to four 1 MiB files, so very old offline events can
rotate out. iOS controls background opportunities.

Mac logs live in `~/.orbit/Logs/events.jsonl`; received phone journals live in
`~/.orbit/Logs/Phones/<paired-phone-id>/`. Set `ORBIT_HOME` to use another state
folder. An agent can call `orbit_diagnostics` or run `bin/orbit diagnostics` to
read recent Mac events and list phone IDs, then use
`bin/orbit diagnostics --phone PHONE_ID --limit 100` for that phone. Diagnostics
are local to your devices and available only through the Mac's local control
socket. Build console logs remain available through `orbit_job`.

Apps created with the bundled **orbit-debug** skill also record screens, actions
and operation results by default. Orbit Mac automatically collects their private
journals over Xcode's existing native phone connection. Call `orbit_diagnostics`
to list app IDs/status, then use `app` or `bin/orbit diagnostics --app APP_ID`.
Applets record action sequences automatically; their copied prompt also requests
screen/branch breadcrumbs. Hosted applets use the phone journal; standalone
exports include the app helper. Existing native apps need source instrumentation
and a rebuild. No logging switch, manual export or hosted service is involved.
See [app debugging](docs/app-debugging.md) for integration and connection limits.

The iPhone Apps page shows fixed-size cards with Home Screen-size icons.
The grid fits more columns in wider windows; the cards keep the same size. A history clock and last-built age (like **14hr** or **2d**) sit beside
Play; a dash means the app has not been built yet. Errors show a small red **!**
without resizing the card. Tap anywhere except Play to expand the card inside
the screen’s safe area. It keeps the same icon and build controls, adds refresh
settings and build caching, and has icon buttons for logs, cancellation and
removal. All controls stay visible; long status/error text scrolls in its own box.

The iPhone Apps list loads independently of job-console reads, shows errors with
Retry, and explains how to add apps when the catalog is empty. Tap the play
button beside an app to build and install it in one press. Connect the phone to
Wi-Fi first; Orbit checks before requesting a build and explains how to retry
when the phone is on cellular alone. Expanded cards hold
schedules, cancellation and console actions. If CoreDevice loses access after an
iOS update, Orbit keeps the signed build and waits for the phone. Open the phone
in a compatible Xcode, then use the same build job to finish installation. An interrupted build reply asks you
to check Apps before retrying, since the Mac may already be building.

If iOS ends live build monitoring, the activity says **Build monitoring paused**.
Open Orbit to get the Mac’s result; the build can continue there. Only a confirmed
failed or cancelled job uses a failed activity. The progress sheet centers the app
name and shows the build action separately above it.

## Quick path with an agent

Clone this repository and ask your agent:

> Read Orbit's README and AGENTS.md. Help me install Xcode and Orbit, sign in to my own Apple Personal Team, connect my phone, choose a pipe, then add my app and refresh it every six days. Keep account credentials in Xcode. Ask me to perform Apple sign-in and trust prompts myself.

Install the bundled plugin or [MCP](#connect-your-agent) once the Mac app is running. An agent can discover phones, inspect repositories, register an app it just created, start a build, read its log, and change its schedule.

## 1. Prepare your Mac and Apple account

1. Install the full [Xcode application](https://developer.apple.com/xcode/) supported by your Mac and iPhone OS. Orbit's iOS client targets **iOS 26+**; its Mac client targets **macOS 15+**. Use Xcode 26.2 or newer for Orbit. The apps you add can support older iOS versions.
2. Open Xcode once, accept its license and install requested iOS platform components. In Xcode → Settings → Locations, select that Xcode for Command Line Tools. `xcode-select -p` should point inside the full Xcode app, not just `/Library/Developer/CommandLineTools`.
3. In Xcode → Settings → Accounts, add your Apple Account. Create an account through Apple's sign-in flow if you need one. A free account appears as **Personal Team**. If you already pay for the [Apple Developer Program](https://developer.apple.com/programs/enroll/), choose that team instead. Do not enroll in the paid program just to try Orbit.
4. Connect your iPhone by USB, unlock it, choose Trust on both devices, and enable [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device). In Xcode's Devices and Simulators window, finish pairing and enable Connect via network. First installation and any Apple trust prompts require your attention.
5. If needed, run a small app once from Xcode with your selected team. Resolve account agreements, signing and device support in Xcode before automating them. Orbit uses this existing setup; Mac builds do not ask for your Apple password or export a signing key. Optional phone refresh has its own explicit Apple sign-in on iPhone.

Install [Homebrew](https://brew.sh/) if you use it, then:

```sh
brew install go xcodegen python
# Install Rust with rustup, then add the Apple targets.
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
# Optional: useful for private GitHub repositories and development.
brew install gh
```

Git and Swift come with Xcode. Go builds Orbit's small transport and Apple installation helper from source. Python runs the CLI/MCP. XcodeGen generates the app project. Rust builds the pinned Iroh transport for Mac, iPhone and Simulator. The DMG includes the native archives for end users.

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

Use your own unique reverse-DNS prefix and your team identifier from Xcode. The resulting apps are `com.yourname.orbit.ios` and `com.yourname.orbit.mac`. To keep an existing phone identity exactly, add `ORBIT_IOS_BUNDLE_IDENTIFIER = your.existing.bundle` to the same ignored file; its Share and Widget extensions follow that identifier. Detached self-builds use this local identity too and stop if it is missing or still uses sample values. Neither app requires App Groups, iCloud or Luna’s premium system. The iOS app and widget extension explicitly share the containing app’s Keychain access group; it is separate from Luna’s identities. No developer account or team ID is included in the repository. Use the same local identity for Xcode, Simulator validation and builds started from Orbit.

Open `Orbit.xcodeproj`. Select the **Orbit** scheme and your phone, then Run. Xcode uses automatic development signing. The phone may ask you to trust your development certificate in Settings → General → VPN & Device Management. Keep the app installed; reinstalling from scratch can discard its local drafts and pairing identity.

Builds of older DMG-installed phone source restore a missing local identity file
from matching saved setup, app and phone settings before building. Existing local
files stay authoritative. Developer checkouts still require their own local config.
When Orbit Mac was installed from a source checkout, setup and phone self-builds
use that checkout's local identity. Older bundled-source catalog entries move to
the canonical checkout. A self-build whose bundle ID differs from the configured
phone app or the requesting Orbit app stops before installing another copy.

For the Mac, choose **OrbitMac → My Mac → Run** in Xcode, or run:

```sh
./scripts/build_and_run.sh
```

Both build the latest **committed** revision and install the complete app at
**~/Applications/Orbit Mac.app**. Commit your changes first. Xcode Run launches
and debugs that same copy. Its build product links to the installed app, so
Clean Build Folder leaves the installed app intact. Agents use the same script. Builds use a detached
worktree and leave your working files and index alone.

Orbit remembers the installed bundle ID, exact signing certificate, source
checkout and state folder. Updates verify the old signing requirement before
closing Orbit, then replace the bundle at its fixed path. The first update can
adopt the certificate of an older running Xcode copy. If several development
certificates match on first installation, select one once with
`ORBIT_MAC_SIGNING_IDENTITY='EXACT CERTIFICATE NAME OR SHA-1'`. Future builds
reuse it automatically. A missing certificate or changed identity stops the
update. Pairing, app lists and jobs stay in the same `~/.orbit` folder; existing
custom state roots are pinned too. macOS owns its permission grants; keeping the
same signing requirement, identity and location prevents routine rebuild drift.

In either client, open **Apps → Orbit Mac → Rebuild Orbit Mac** to apply the
latest local commit. Orbit Mac has its own section, separate from phone apps.
Agents can use `orbit_mac_update` and `orbit_mac_update_status` through MCP, or
`bin/orbit mac-update` and `bin/orbit mac-update-status`. The worker keeps running while Orbit restarts; progress, logs and failures survive
reconnection. Success requires the reopened canonical app to report the expected
revision. Finish phone builds first. The Mac must be awake and logged in, with
its source checkout and signing key available. This action never fetches, commits
or discards source changes.

`--build-only` creates a separate `dist/Orbit Mac.app` review artifact without
replacing the installed app. The **OrbitMacBuild** scheme is for native Xcode
compilation checks and produces `OrbitMacClient.app`; use **OrbitMac** for everyday Run. Both package the native
Apple helper. The normal Run flow also includes setup source and agent resources.

Allow Local Network access on both devices. Grant the Mac app access to source folders when macOS asks. If projects live under Desktop/Documents or other protected locations, access depends on macOS permissions. Move projects to a normal development folder if that is more convenient.

## 3. Choose a pipe and pair

Orbit owns application-level trust independently of the pipe. A route is never proof of identity. Pairing pins a certificate identity for TCP/Syncthing or an iroh endpoint key for dumbpipe; the Mac explicitly approves the phone. There is no automatic switch to a public relay when a local route fails.

| Choice | Setup | What it does |
| --- | --- | --- |
| Local Wi-Fi | Both devices on your LAN; no extra software | Direct encrypted connection, with no intermediary or external discovery |
| Tailscale | Install and sign in to the separate client on both devices | Direct/relayed networking according to your tailnet policy; Orbit still authenticates its own connection |
| Syncthing relay | Provide an explicit `strelaysrv` URL | Carries Orbit's end-to-end authenticated streams; this is the Syncthing relay protocol, not a synced-folder job queue |
| dumbpipe / iroh | Choose the built-in adapter | Tries LAN, then direct Iroh, then optional Tailscale. Public Iroh relays help set up the connection. |

With Automatic remote connections, Orbit syncs the Mac’s relay address to the paired phone so it can connect even when endpoint discovery fails.

Detailed commands, private relay setup and troubleshooting: **[Pipes](docs/pipes.md)**.

Open **Orbit Mac → Settings** (⌘,) and choose **Local Wi-Fi**, **Automatic (iroh)**,
**Tailscale**, or **Private Syncthing relay**. The same picker is in **Phone & Remote Setup**.
For Tailscale, connect both devices to your tailnet, enter the Mac’s Tailscale IP or
MagicDNS name, and click **Apply Connection**. If switching from iroh, open the
updated iPhone app on the same Wi-Fi and let it sync before and after applying.
Orbit tries the tailnet address first and keeps local Wi-Fi as a fallback.
**More → Mac** on iPhone shows the saved connection type.

For your first phone, click **Connect a Phone**, copy the code, and paste it into
the iPhone app’s **More → Mac → Connect a Mac**. Compare the phone ID on both devices
before approving on the Mac. Pairing lasts five minutes. After that, connection
changes sync automatically while Orbit is open and connected. Keep an offline
phone on the same Wi-Fi until Settings shows it updated before leaving home.
Both clients need the route-sync update; their existing pairing is preserved.
CLI configuration remains available for automation in [Pipes](docs/pipes.md).

For native USB/Wi-Fi deployment, you can use only the Mac client and CLI/MCP and skip installing the Orbit iOS client, leaving all three free-account app slots available for your own apps. The iOS client adds source editing, remote control and phone-side forwarding.

You can build/install through Xcode's native USB or Wi-Fi connection without an iPhone control app being awake. Remote-control reachability and Apple installation reachability are different: putting both devices on a tailnet alone does not make CoreDevice discover the phone. Orbit includes a separate bounded forwarding path for remote installations; see [remote installation limits](docs/architecture.md#remote-installation).

## Build apps on this Mac

In **Add App → This Mac**, choose an Xcode project/workspace or a Swift package’s
`Package.swift`, then enter its shared Mac app scheme or executable product.
Only add source you trust. **Build and Open** builds the selected committed branch
in a detached worktree, replaces the installed app and opens it on the host Mac.
The paired phone’s Apps list and CLI/MCP can start and monitor the same targets.

Orbit finds an existing running copy first, then installed copies with the same
bundle ID. It keeps that app’s exact path, bundle ID, certificate and signing
requirement. Swift package apps also retain the existing Info.plist and
entitlements. Your preferences, Application Support files and Keychain stay in
place, including phone pairing. New apps default to `~/Applications/<name>.app`
and need a unique bundle ID and one available Apple Development certificate.
Multiple matching certificates/copies require an explicit choice.

Advanced settings let you choose the installation path, bundle ID, exact signing
certificate (name or SHA-1), Debug/Release configuration, branch and schedule.
A new Swift package app can use an Info.plist file for its app name, permission
copy and other metadata. Existing installations reject identity/location changes
while running; use their current settings for updates. Orbit itself keeps its
separate **Rebuild Orbit Mac** action and ignored local identity configuration.

```sh
bin/orbit add --platform macOS --project /path/to/Package.swift \
  --scheme MyMacApp --branch main --trust
# For a new app, add --bundle-id com.yourname.myapp.mac.
# Optional: --install-path '/Applications/My App.app'
#           --signing-identity 'EXACT CERTIFICATE NAME OR SHA-1'
#           --configuration Release --info-plist /path/to/Info.plist
bin/orbit build TARGET_ID
bin/orbit job JOB_ID
# Install without opening:
bin/orbit build TARGET_ID --no-launch
```

`orbit_add_target` accepts the same `platform: "macOS"` and settings through MCP;
`orbit_build`, `orbit_job`, `orbit_cancel` and `orbit_schedule` share the Host
catalog. Mac schedules are optional and default to 144 hours when enabled.
Local sources never fetch automatically. Jobs survive Orbit restarting; build
cancellation stops the worker’s command group. Replacement waits for signature
checks before closing the app, retains a rollback bundle until requested launch
is verified, and reads the installed executable back before recording success.
An uncertain interrupted installation retains recovery files and blocks automatic
retry until it can be verified. Generic Swift package packaging supports static
executables and SwiftPM resource bundles; projects needing custom embedded
frameworks/helpers or extensions should provide an Xcode app target.

## 4. Add an app

Start with a project you trust. Xcode projects, package plugins and build phases can execute code on your Mac. A GitHub compatibility check finds an Xcode project before cloning; it is not a security review or a promise that an arbitrary repository will compile.

In the Mac client, **Add App** opens **On This Mac** or **GitHub**. Project
previews load from a saved cache immediately and update in the background without
opening Xcode. Pick an app (with its icon) and a phone by name; the last used or
setup phone is selected for you. **Advanced** holds branch, signing account and
refresh settings, with free Personal Team refreshes defaulting to six days.
Adding asks you to trust the source before Xcode validates it, then opens Apps
with a confirmation and the new app ready to build. GitHub projects download
before app selection; download and validation progress stay visible.

On iOS, use **Apps / Add App**. Orbit automatically finds `.xcodeproj` and `.xcworkspace` projects on your Mac. Pick a detected project, approve reading its source, then choose a runnable iOS app scheme. The iOS client shows the same Mac discovery list. On Mac, **Choose Project…** opens the system file picker for projects elsewhere. You can also browse GitHub, select a repository, and inspect its Xcode project paths. Choose a runnable iOS app scheme, the phone, branch and signing team. Shared schemes make setup reproducible. Library-only Swift packages, Android/web projects and repositories requiring unrun project generators do not qualify until they contain a working Xcode app project.

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

If a build reports **No Accounts**, check the selected team for the app and its extensions in Xcode. This error does not prove you’re signed out. **Missing Xcode-Token** means the build tools couldn’t load a saved signing session; check Xcode → Settings → Accounts on your Mac. Capability errors need a matching profile for the failing app or extension. For **App Groups**, use that target’s explicit App ID with its shared group enabled, then refresh automatic signing. A wildcard profile cannot supply App Groups. Orbit names the capability on the phone and keeps the full Mac job log.

Local iOS projects without Git build from the files saved in their folder on the Mac. For Git projects, commit the source you want to install. Orbit builds the selected branch in a detached worktree. Targets cloned by Orbit fetch the chosen GitHub branch before each fresh build without changing the checkout’s active branch.

In iOS **Apps**, **Build and Install** opens live progress with the current operation, live completed/running task counts and a console. Xcode does not provide a reliable total task count, so running builds show an activity indicator instead of an estimated percentage. Close it to keep watching progress in the app tile or Project tab. The system build Live Activity continues monitoring while iOS permits background processing; reconnect status appears if the Mac goes away. The activity starts after the Mac accepts a job. If iOS stops monitoring, check progress in Orbit; reopening does not create a second activity for that job. Self-updates finish that activity before replacing Orbit, and installation is complete only after the Mac verifies it. If the update cannot start installing, the progress screen shows the recovery message.

On iOS, Play defaults to **Build & Install**. Enable **Launch After Install** in a
scheme's row menu to open the app too. Each scheme keeps its own preference,
including schemes for the same app. Install-only builds compile for a generic
iOS destination and skip launching, so locking the phone after the build starts
doesn't cause a launch failure. The Mac still needs its trusted native Apple
connection for installation; device trust or installation prompts may require
unlocking. With launch enabled, keep the phone unlocked for that final step.

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

Orbit starts its MCP service whenever the Mac client is running. Its authenticated
Streamable HTTP endpoint listens only on loopback (normally `127.0.0.1:49211/mcp`); the owner-only
`~/.orbit/mcp-http.json` contains the connection settings and a token rotated each
launch. No separate macOS MCP permission is needed. Folder and Local Network
consent live together in setup. External MCP hosts still need their own server
entry; Orbit does not modify other apps’ settings.

The existing stdio MCP remains available for hosts that launch their own adapter.
Both transports use Python’s standard library and the running Mac app’s owner-only
Unix socket. No agent SDK or AI API key is required.

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

For a visual review of the full Mac setup wizard, run
`scripts/capture_setup_screenshots.sh`. It renders the actual SwiftUI view with
fictional data and inert actions. See [mock screenshots](docs/testing.md#mock-mac-setup-screenshots).

[Architecture and limits](docs/architecture.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

Orbit was extracted from Luna Code. It has independent app identities and storage; it does not read Luna's App Group or migrate Luna's Apple credentials. MIT licensed; third-party components retain their own licenses.

Refresh setup on iOS presents the next incomplete step with numbered progress. Setup details keeps certificate import and account maintenance available. Phone authorization probes native Apple challenge delivery and accepts only proof signed by the running client’s installation identity; no phone picker is shown.

The iPhone Apps page shows its last successful list immediately, then refreshes
on opening. Offline refreshes keep the saved list for the same paired Mac.
