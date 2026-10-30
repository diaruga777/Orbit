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

The client app icons live in `Apps/Orbit/Assets.xcassets` and
`Apps/OrbitMac/Assets.xcassets`. Both Xcode targets select `AppIcon`.
The Mac packaging script converts the same Mac PNGs to `Orbit.icns` and declares
`CFBundleIconFile`, so Xcode and packaged apps share their Dock/Finder artwork.
The iOS master is opaque and square for system masking; the Mac artwork includes
transparent padding and rounded corners. Both use solid white device silhouettes
on black, subtle glass edges on the devices, and a thin white orbit that tapers
before the phone. See [app icons](design/app-icons.md).
The `OrbitMac` Xcode scheme builds the `OrbitMacClient` app target, keeping its
build intermediates separate from the `OrbitMac` package library.

## Mac setup and optional setup

The active wizard has six steps: welcome, tools, folder access, Apple account,
iPhone, ready. Legacy agent/install/connect/refresh step values migrate without
changing existing source, signing identifiers or durable installation job IDs.
Phone-only refresh is not required by the wizard. A dismissible banner in both
clients links to phone refresh and remote building after setup. Local Wi-Fi stays
the default; the Mac’s Phone & Remote Setup sheet explicitly enables the existing
iroh transport immediately and shows startup errors and phone sync progress.
Connection options also configures local Wi-Fi, Tailscale and explicit Syncthing
relay URLs without a CLI. Tailscale clients/account and private relay hosting
remain user-owned external prerequisites.

The server serializes live listener changes, starts replacements before retiring
old remote listeners, and keeps the local listener available. Host configuration
is saved after activation succeeds. Authenticated `connection_routes` exchanges
carry per-transport Mac pins and enroll phone transport aliases under the original
trusted account. Control and Apple reverse streams resolve those aliases to the
same account, preserving installation bindings; `forget` removes all aliases.
Phone snapshots persist separately from the original pairing and sync on activation
and every ten seconds while active. Offline phones retain their last authenticated
snapshot until reachable again; updated routes replace retired routes after sync.
No new trust window or public identity lookup substitutes for authentication.
Phone forwarding renews readiness after snapshot changes or expired leases and
resolves the current pinned route for each separate Apple stream, including iroh.

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
Team discovery merges current Xcode team caches (`IDEProvisioningTeams` and
`IDEProvisioningTeamByIdentifier`) with the legacy team-manager cache. Available
Xcode metadata needs no certificate; only an empty team cache falls back to a
non-interactive public-certificate query, without requesting private keys.
The wizard auto-selects a sole team, otherwise shows names, and generates a stable
random bundle namespace in user state. Existing registered/installed identities
are preserved, and a phone is rechecked natively before installation.

`CodeXcodeTools` resolves a full Xcode for both Mac process runners, so phone
listing, readiness and deployment use the same selection policy. An explicit
`DEVELOPER_DIR` is honored (and errors if unavailable), followed by a valid
system-selected Xcode. Standalone Command Line Tools or a removed selection fall
back to the running Xcode, Launch Services, then installed Xcode applications.
The resolved directory is passed to child commands; system settings stay intact.
Discovery failures retain bounded Xcode diagnostics instead of blaming the cable.
Mac updates synchronize the verified bundle exactly at the existing installed path
and verify it again afterward, removing obsolete resources across toolchain bundle
layout changes while keeping the bundle identifier and signing requirement.

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

Optional inert `pollHours`/`notifications` metadata grants scheduled applet checks.
`OrbitAppletRunner` serializes foreground actions and native polling per stored
applet. A fresh VM runs only `poll(ctx)`; its output is validated without calling
render/update. Storage and the bounded alert outbox commit in a single
ThisDeviceOnly record after source readback. Stable event IDs deduplicate the last
64 deliveries. Failed checks preserve prior data and back off 15 minutes; an
interrupted check retains its retry lease. Successful checks advance by the
requested hours; notification submission failure retains the outbox. The iOS
composition requests BGAppRefresh windows and catches up every minute while
active, with cancellation on expiration. iOS controls actual execution times.
Permission prompts occur in the foreground; denied alerts are dropped while
checks continue. Tapping an alert opens the installed applet. Standalone hosts
register the same scheduler and restrict execution to the consented bundled digest.
No push entitlement, paid capability, hosted scheduler or AI dependency is added.

The phone reviews every import/update before evaluation. Mac drag-and-drop,
file selection, CLI/MCP and folder additions share the Host script catalog.
`script_import` infers kind from validated inert metadata; existing `applet_add`
and `widget_add` retain their kind checks. Defaults are Applets/Widgets under the
setup folder (or the legacy state root before setup); `script_folder` stores a
per-kind override and copies existing imports without overwriting user files.
Existing private deployment queues migrate once. The selected folders are the
catalog, scanned every two seconds and on listing, including saves and renames.
Only top-level .js files are checked: bounded UTF-8 regular-file reads, no symlinks
or execution. Invalid files produce local diagnostics independently; at most 24
scripts per kind are delivered. Content determines kind across both folders;
for duplicate IDs the most recently saved valid file wins, with a diagnostic.
Mac removal deletes matching files from the selected folders; already-approved
phone copies remain independent. A paired phone can list source but cannot
mutate Mac files, choose folders or export projects.

While active, the phone polls the pinned paired Mac every ten seconds and on
activation. Unapproved snapshots are stored separately in the same ThisDeviceOnly
Keychain service, with tab badges and review rows. Offline failures preserve the
last received queue. Exact installed sources and dismissed digests are skipped;
changed sources require fresh consent and stale review confirmations are rejected.
No unapproved script touches executable records or private K-V state. iOS controls
background opportunities; immediate delivery while Orbit is closed is not promised.
The file browser and Open in Orbit route by the same header parser. A native
share extension accepts one JavaScript file, shows metadata/website consent, and
writes an approved script through the existing containing-app Keychain group.
It never evaluates source and adds no App Group or iCloud entitlement.

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

## iPad navigation

The iOS client uses the system tab/sidebar layout so every destination is available in wide windows. The project browser keeps its existing split editor. Rotation is declared for both device families; compact windows keep UIKit’s tab navigation. Target and job menus anchor to their selected rows, while import choices anchor to Add.

## Public website

`website/` contains a standalone static landing page. It shares Orbit’s native
light surfaces, system typography, blue accents and code colors without linking
any application runtime. Its interactive product illustration uses fictional
projects and does not perform builds or connect to devices. Theme preference is
the only browser-local state; there are no analytics, external fonts, account
forms, API calls or secrets. Relative asset paths support the `/Orbit/` Pages
base path. The isolated Pages workflow uploads only `website/`; source and
release assets stay in GitHub’s repository and Releases services. See
[website hosting](website.md).

Refresh setup on iOS presents the next incomplete step with numbered progress. Setup details keeps certificate import and account maintenance available. Phone authorization probes native Apple challenge delivery and accepts only proof signed by the running client’s installation identity; no phone picker is shown.

## Local project discovery

Host `projects_detect` scans configured project roots and the Mac home folder using filesystem metadata only. It skips hidden folders, symlinks, caches, dependencies and package contents, deduplicates paths and bounds results to 500 projects and 100,000 entries. Inaccessible folders are skipped; Choose Project on Mac uses NSOpenPanel for other locations. Trusted paired phones can request the same scan. `project_apps` requires explicit source trust before invoking the existing Xcode runnable-iOS-app validation. Both clients select schemes from that response; registration revalidates the selection and existing committed-worktree build rules apply. Discovery does not build, install or fetch repositories.


Mac Add App prewarms inert project previews at Host startup and stores snapshots
in user-owned `project-previews-v1.json`. `project_preview` reads bounded pbxproj
and scheme/workspace XML plus icon assets; it never invokes Xcode, resolves
packages or executes source. Cached rows appear immediately while startup or
manual discovery refreshes them. Registration still requires explicit source
trust and Xcode validation. Automatic schemes must match their own target name,
so an app dependency cannot turn a library scheme into an app choice.
GitHub download (`repo_prepare`) is separate from app selection and registration;
retries reuse only a checkout whose origin matches, and never reset working files.
The Mac remembers the last successfully added phone and otherwise uses setup’s
phone. Advanced settings default to the detected local branch, setup signing
account and 144-hour Personal Team cadence. Successful registration merges the
returned durable target into Apps and selects that tab with a success banner.
Target-list responses return immediately; legacy icon backfill runs independently
with the existing five-minute failure throttle.
