# Architecture

Orbit is independent of Luna. It contains a source editor, a Mac executor and transport adapters; it does not link Luna's Vault, Music, premium, app configuration or saves database.

| Component | Responsibility |
| --- | --- |
| `OrbitCore` | Codable requests, revisions, drafts, job state, retained artifacts, phone-bound install grants |
| `OrbitMac` | File editing, SourceKit, Xcode build jobs, isolated Git worktrees, signing/profile checks, native and bounded remote installation |
| `OrbitRefresh` | Phone-owned Apple sessions, signing, cached IPA validation, LocalDevVPN installation and readback |
| `OrbitWidgets` / `OrbitWidgetUI` | Single-file JavaScript runtime, grants, K-V storage, native widget/applet layouts and consent |
| `OrbitUI` | UIKit editor, syntax highlighting, completion, diagnostics and build views extracted from Luna Code |
| `OrbitWire` | Peer IDs, bounded byte streams and pairing routes |
| `OrbitTransport` | Source-built Go mutual TLS, explicit Syncthing relays, native iroh streams, framing and phone-owned service forwarding |
| `OrbitHost` | App catalog, GitHub browsing/inspection/import, persistent schedules, local control socket and authenticated remote server |
| `OrbitMacApp` / `Apps/Orbit` | Standalone Mac and iOS composition and setup |
| `bin/orbit` | Python CLI and stdio MCP using the same running Mac service |

Data lives under `~/.orbit` on Mac (override with absolute `ORBIT_HOME`) and private Application Support on iOS. Pairing certificates and iroh keys are independent of signing certificates. The phone's installation authorization key is non-synchronizing and stays in Keychain. Removing an app or its state requires pairing again; no Luna identity is silently adopted.

## Mac setup and optional setup

The active wizard has six steps: welcome, tools, folder access, Apple account,
iPhone, ready. Legacy agent/install/connect/refresh step values migrate without
changing existing source, signing identifiers or durable installation job IDs.
Phone-only refresh is not required by the wizard. A dismissible banner in both
clients links to phone refresh and remote building after setup. Local Wi-Fi stays
the default; the Mac’s Phone & Remote Setup sheet explicitly enables the existing
iroh transport and explains native installation authorization and restart/re-pair.

`OrbitToolInstaller` runs the upstream Homebrew/xcodes installer through a private
pseudo-terminal inside the wizard. It installs missing full Xcode and Python,
selects a stable Xcode compatible with the current macOS using the upstream
release feed, finishes Xcode’s first launch and downloads the iOS platform. Homebrew is installed
only if needed; shipped phone source/native archives avoid end-user Go/XcodeGen.
Terminal output is bounded, transient and excluded from diagnostics and setup
state; input uses a secure field with terminal echo disabled. Xcodes owns Apple
download credentials in Keychain. Signing remains Xcode-owned: the wizard reads
public Xcode team metadata and development certificate subjects, never account
sessions or signing keys. Xcode’s native Accounts screen handles signing login.
The wizard auto-selects a sole team, otherwise shows names, and generates a stable
random bundle namespace in user state. Existing registered/installed identities
are preserved, and a phone is rechecked natively before installation.

Folder consent defaults to `~/Desktop/Orbit`, creates/tests the folder after an
explicit action, and updates the Host’s project-root preference. GitHub imports
use that selected folder. Existing target source paths remain durable.

The Mac starts a separate Python MCP HTTP adapter after its local service starts,
retries startup as tools become available, and owns its lifetime. The adapter
binds only `127.0.0.1` (port 49211, or an available port if occupied), validates Host/Origin, requires a random bearer token,
bounds requests/connections, and uses the same CLI tool inventory and Host socket
as stdio. `mcp-http.json` is owner-only secret state, never a public progress file.
Tokens rotate on adapter startup; clients must reload connection settings after a
restart. External hosts may continue using stdio without token management. There
is no OS-level MCP entitlement or automatic edit of another app’s configuration.

## Requests and jobs

The local CLI uses a Unix socket inside the owner-only state directory. Remote peers use mutually authenticated TLS or pinned iroh endpoint keys and must be explicitly trusted by the Mac. Control frames begin with `ORBT`, followed by a four-byte big-endian JSON length; the 12 MiB cap is checked before payload allocation. Each RPC uses a fresh bounded exchange. Installation streams use their separate LCDF protocol and phone-key proof.

The Mac checks its schedule every minute. Success means a confirmed installation, not just compilation. Submission IDs and pending requests are persisted before dispatch; jobs, logs, artifacts and install evidence survive restart. Builds use a detached checkout of the configured committed branch. GitHub-managed targets fetch their configured branch; local targets never pull or rewrite the user's checkout.

App targets retain the configured Xcode app-icon thumbnail discovered at registration and send it to both clients' Apps lists. Older catalogs fill missing icons on listing without building or installing an app. Unavailable projects and missing icons keep their rows with a placeholder; failed icon lookups retry after five minutes rather than on every poll.

The iOS Builds tab stores `launchAfterInstall` per paired Mac, project path and
scheme; missing preferences default to false. Discovery preserves it alongside
branch and device choices. Play sends `CodeDeviceBuild.installOnly = true` by
default, using the existing generic-iOS compilation path and native install
without `devicectl device process launch`. Opting in restores Build & Run and its
device-specific destination. Accepted work belongs to the Mac and continues if
phone monitoring disconnects. The `.remote-build` continued-processing task is
declared in the phone's permitted background identifiers for status monitoring
and the existing self-update handoff; iOS still controls its lifetime.

Profile refresh is scoped to the selected automatic-signing team, bundle identifier and phone. Only cache entries expiring before the requested lifetime are moved aside, with a recovery journal. Xcode does the actual provisioning. The built app and extensions are checked before deployment. Credentials remain in Apple's existing tools.

## Remote installation

A control pipe by itself does not expose Apple's installation services. Native deployment uses the Mac's existing Xcode/CoreDevice USB or Wi-Fi connection. The optional remote path:

1. Enrolls the physical phone while that native Apple connection can verify its private installation key through its own Orbit app container.
2. Lets the phone advertise short-lived readiness while Orbit runs.
3. Opens a fresh phone-initiated, authenticated stream for each bounded Apple service demand.
4. Restricts forwarding to Lockdown and authenticated dynamic AFC/Installation Proxy ports on that phone's own interfaces.
5. Uses the Mac's existing selected pairing record through the bundled helper, pins the paired device certificate, validates UDID, installs the retained signed artifact, and reads back exact bundle/version/build.

No arbitrary host/port proxy, host-key export, new device pairing, Developer Mode enablement or UI automation is offered by this path. Self-replacement of the app carrying the forwarding session is rejected. Updating Orbit itself requires the independent native Apple path or the separate phone-side LocalDevVPN refresh connection.

The iOS client offers readiness in the foreground and requests BGProcessing windows for later attempts. iOS decides whether and when a background window runs; expiry, lock state, Wi-Fi policy and Apple's device services can prevent installation. Artifacts remain waiting, and uncertain completion is reconciled before retry. The inherited implementation has synthetic Apple/TLS/relay coverage; **the standalone Orbit extraction has not been accepted on a physical phone or a free Personal Team in CI**. Do not infer those results from simulator builds.

## Known boundaries

- An Xcode project-file check is preliminary. Private dependencies, missing secrets, unsupported entitlements, nonshared schemes or an unavailable SDK can still stop a build.
- Apple's Personal Team restrictions remain in force. Automated refresh cannot create more app slots or add paid capabilities.
- The native dumbpipe-style adapter uses iroh with Orbit's ALPN, not the stock desktop CLI's default protocol.
- The Mac must be logged in, awake, with Xcode account access available. No always-on Luna/Orbit hosted service fills that role.
- There is no automatic signing-key migration. The Mac DMG bundles a resumable setup wizard and phone source; it signs the iOS clients with the user’s own account. Public DMGs require Developer ID and notarization, separately from review packaging.
- WidgetKit controls network refresh scheduling. JavaScript runs in the installed host extension; new scripts do not create native extensions. See [widgets](widgets/README.md) and [phone refresh](local-refresh.md).

## JavaScript applets

Applets use an inert `orbit-applet` JSON header, exact-host HTTPS grants and the
widget evaluator's quotas/deadline. `update` runs on launch/reload; `action` receives
a control name and string inputs before `render`. Each invocation has a fresh VM;
private JSON storage is committed only after validated output. Widgets reject
interactive nodes. Applets use a separate `Orbit.Applets.v1` Keychain service,
scoped to the containing app's access group, with ThisDeviceOnly state.

The phone reviews every import/update before evaluation. Mac `applet_add` queues
source without executing it; a paired phone can list but cannot mutate Mac files
or export projects. CLI/MCP and Mac UI share the Host catalog and exporter.

`Sources/OrbitHost/Resources/AppletHost` contains the canonical shared runtime,
SwiftUI applet view, standalone entrypoint and Xcode template. SwiftPM compiles
the same runtime/UI sources used by exported projects. Export copies these
resources into a new self-contained repository and commits it on main, with a
user-owned bundle ID and normalized 1024px icon. No external package, paid
capability or Orbit connection is needed by the standalone host. First launch
and changed script digests require local consent. Builds/install/schedules go
through the existing trusted target and detached committed build pipeline; the
export itself never installs.

## Installed-app expiry and setup reminders

Mac builds retain the earliest embedded app/extension profile expiration in
`CodeBuildArtifact.profileExpiresAt`. Confirmed native editor installs and
retained scheduled installs record device, bundle, version/build, installation
time and optional expiry in a separate `installed-apps.json` journal. Compilation,
IPA caching, a control connection and uncertain installation do not create this
evidence. Old retained confirmed jobs backfill the journal; missing profile dates
use seven days from confirmed installation, never an assumed paid-team year.

After installing Orbit, the Mac copies a public receipt to the fixed
`Documents/OrbitInstallation.json` path in that app’s private container using the
native, UDID-verified Apple connection. This identifies the phone before optional
remote authorization; it grants no installation authority and holds no secrets.
Existing endpoint bindings provide an alternative for older installations.
The phone’s `installed_apps` RPC requests its device snapshot. A successful native
inventory removes missing/replaced revisions; unavailable devices keep the last
confirmed snapshot. Each phone filters and persists only its own entries. The
running Orbit bundle supplies its profile expiry even without a Mac connection;
confirmed phone-side renewals supersede older Mac evidence. Imports alone do not.
Apps installed outside Orbit cannot generally be inventoried from an iOS sandbox.

The phone syncs on foreground entry and once a minute while active. Local refresh
changes also recompute the reminder. `UNUserNotificationCenter` owns a single
non-repeating request 24 hours before the earliest future expiry. A first late
sync inside that window delivers immediately; repeated checks do not repeat a
delivered reminder for the same expiry. Renewal replaces the pending deadline.
Configured account, certificate, pairing file, current Orbit cache and a successful
connection check cancel the
setup reminder; a transient VPN disconnect does not reclassify setup as incomplete.
Notification authorization is requested in the foreground only when there is an
installed app to protect. Denial leaves the existing setup banner available.
Tapping the notification uses the same Refresh destination as the banner, including
cold launches and overflow tabs. It does not start Apple sign-in or installation.
