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
The everyday `OrbitMac` scheme builds `OrbitMacInstall`, a native application
product whose script runs the same `scripts/build_and_run.sh --install-only`
entrypoint as agents and in-app updates. After successful installation,
`scripts/xcode_mac_product.py` atomically links its DerivedData product to
`~/Applications/Orbit Mac.app`. Run/Profile use `BuildableProductRunnable`, so
Xcode resolves the app through build settings instead of a literal `$(HOME)`
PathRunnable (which Xcode does not expand). The script declares the installed
Info.plist/executable as outputs; Xcode does not compile, generate metadata for,
or re-sign this product. Clean removes the DerivedData link, leaving the installed
app intact. No generated scheme contains a developer's absolute home path.
`OrbitMacBuild` retains the native `OrbitMacClient` target for compilation checks;
its product and scheme consistently name `OrbitMacClient.app`.

The coordinator in `scripts/mac_build.py` serializes builds with a per-user flock,
validates ignored local identity, and packages only a committed HEAD in a detached
worktree. Native archives and private local config are copied. Each fresh detached checkout
uses the reserved `~/.orbit/MacBuildSource` path, and SwiftPM uses an explicit
`MacBuildCache` scratch path, so binary-artifact paths survive repeated builds.
A stale reserved checkout is removed only if Git registers it as detached in the
same repository; a branch or unknown folder stops recovery. User build trees are
never reused. The
complete packager is `package_mac_app.sh`. Development packages support debugger
attachment; public release packages retain hardened runtime/notarization rules.

`~/.orbit/mac-installation.json` pins the canonical path, bundle ID, leaf-certificate
SHA-1, designated requirement, original checkout and absolute state root. The
first migration can adopt a running development copy's certificate. Each update
verifies the staged signature, exact certificate and old requirement before
stopping any process. It stops only matching bundle IDs, stages a full replacement
beside the destination, and restores the previous bundle if replacement fails.
Canonical bundle metadata pins state independently of Xcode/agent environment;
UserDefaults continue using the same bundle ID. Obsolete copies redirect to the
canonical app; additional processes focus the existing copy before starting Host.

Host's authenticated `mac_update` and `mac_update_status` methods (also exposed
through the shared CLI/MCP) are separate from
the phone target catalog. No caller supplies executable paths or revisions. The
installed worker reads the original checkout and builds its local committed HEAD,
without fetch/reset/commit. A detached process inherits the update lock and writes
an owner-only durable `MacUpdate/job.json` and log. Both clients show a separate
Orbit Mac section; phone reconnection resumes status reads. Phone compilation and
installation are gated during Mac maintenance, and active builds prevent update
start. The reopened canonical bundle's path and revision must match the journal
before success; a lost reopen readback stays uncertain. Failures and dead workers
are retained for retry. Xcode's install-only action waits for Run to reopen the app.
The state, pairing identities and installation journals are never recreated.

## Mac setup and optional setup

The active wizard has six steps: welcome, tools, folder access, Apple account,
iPhone, ready. Legacy agent/install/connect/refresh step values migrate without
changing existing source, signing identifiers or durable installation job IDs.
Phone-only refresh is not required by the wizard. The iPhone's explicit More tab
holds separate Phone-only refresh and Remote builds rows, plus Mac connection settings. Each setup row has its own badge;
More is badged when either is incomplete. Phone refresh reads the refresh
engine's durable setup check, including a previously verified connection, while
remote setup reads the authenticated saved route snapshot (falling back to an
original remote pairing for older clients). A saved local-only snapshot clears
remote completion even if the original pairing was remote. Offline/VPN state
does not reset completed setup. Refresh-state, route/pairing and foreground
changes update the badges. Notification deep links open Refresh inside More.
The Mac retains its dismissible optional-setup banner. Local Wi-Fi stays
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

Both the Xcode Mac target and the complete app packager use
`scripts/build_apple_adapter.sh` to build the Apple helper and include its dependency
notices. Xcode signs the embedded helper with its resolved app signing identity
before signing the enclosing app. Pairing export preflights the bundled executable
before creating private output; missing components explain Mac app repair, while
missing Apple trust records explain cable/unlock/Trust. Failed or unsafe outputs
are removed. Export is a local UI action, never an RPC, and requires no prior
phone sign-in or LocalDevVPN connection.

## Phone refresh sign-in

The iOS Refresh account flow uses a keyboard-aware scrollable UIKit form sheet,
with Sign In fixed above the keyboard.
It owns the sign-in task, inline validation/errors, verification continuations and
team selection until the selected team is saved. Cancel cancels the task and
resolves a pending verification request; in-flight work blocks swipe dismissal.
An empty custom server resolves to SideStore’s officially listed HTTPS endpoint
`https://new.ani.sidestore.io`. Advanced retains custom service support, and existing
Keychain account records retain their service URL. Credentials go to Apple;
the current default uses Mac ADI. Orbit reads bounded v3 client metadata and
passes the matching identity through provisioning and Apple authentication.
Provisioning blobs are reused only with the same service and client identity;
a rejected cached blob gets one fresh provisioning attempt on that same service.
Apple authentication is never automatically retried. No hosted Orbit service, server-list
execution, automatic rotation or downloaded native implementation is introduced.
The remember switch controls ThisDeviceOnly password storage. Account state,
optional login and signing key are saved in one atomic Keychain envelope, with
legacy migration after successful writes. Account/team changes clear incompatible
keys; account mutations and installation reconciliation exclude overlapping work.
Signing verifies certificate validity/team and preserves signed entitlements
before upload. Imports acquire scoped file access and run after the picker
dismisses; self replacement waits for background rather than temporary inactivity.
Simulator-only injected services exercise the actual form without Apple sign-in,
helper requests or refresh-secret access.

## Requests and jobs

The local CLI uses a Unix socket inside the owner-only state directory. Remote peers use mutually authenticated TLS or pinned iroh endpoint keys and must be explicitly trusted by the Mac. Control frames begin with `ORBT`, followed by a four-byte big-endian JSON length; the 12 MiB cap is checked before payload allocation. Each RPC uses a fresh bounded exchange. After queuing a reply, the server waits
for the client's close (under the connection timeout) before tearing down the
stream. QUIC writes can complete before delivery; closing immediately could
truncate catalog/build replies even while small connection checks succeeded.
The phone retries reads on alternate pinned routes, but never automatically
replays a mutation after an interrupted exchange. Correlation IDs link the phone
and Mac event journals without retaining request bodies. Concurrent catalog
starts for one target are serialized across suspension points. Installation streams use their separate LCDF protocol and phone-key proof.

The Mac checks its schedule every minute. Success means a confirmed installation, not just compilation. Submission IDs and pending requests are persisted before dispatch; jobs, logs, artifacts and install evidence survive restart. Builds use a detached checkout of the configured committed branch. GitHub-managed targets fetch their configured branch; local targets never pull or rewrite the user's checkout.

App targets retain the configured Xcode app-icon thumbnail discovered at registration and send it to both clients' Apps lists. Older catalogs fill missing icons on listing without building or installing an app. Unavailable projects and missing icons keep their entries with a placeholder; failed icon lookups retry after five minutes rather than on every poll.

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

Before a phone-initiated Build and Install request, the Apps controller (play
button and row menu) and editor phone-build list check a fresh Wi-Fi-specific
`NWPathMonitor` observation. The transport check waits for the first update,
bounds the wait to two seconds, and fails closed without a Wi-Fi path. It does
not infer Wi-Fi from a working control pipe, a VPN or an expensive-path flag;
Wi-Fi hotspots remain eligible. Rejection shows Wi-Fi guidance before starting
build monitoring or sending the build RPC. Retrying probes the network again.
Mac rebuilds, source editing, catalog reads and compilation-only jobs remain
available. This preflight does not prove Apple-service availability or confirmed
installation, and network changes after acceptance still use existing recovery.

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

The Mac app picker groups runnable aliases by project, app name and bundle ID,
preferring the scheme named after the app. UI-test aliases such as LunaMusicUI
therefore stay out of the primary app menu while remaining selectable as a Build
scheme in Advanced. Apps exposed only through a custom scheme remain available.

## Apps build feedback and self-build identity

The phone's editor/control `CodeClient` bridges its encoded request bytes to the
Host's authenticated `code` JSON RPC with `CodeClient.overRPC`. It parses those
bytes as the request object; re-encoding `Data` would send a base64 string and
break editor requests, phone forwarding and self-update acknowledgement while
Apps' separate build/status RPCs still appeared to work. Retained-job recovery
messages remain visible in the running progress screen after a handoff timeout.

Apps and Project share `CodeBuildMonitor`, restored from Luna Code's stage/task
progress, console, durable job reattachment, reconnect handling and
`BGContinuedProcessingTask` system Live Activity. Apps polls the shared Host
catalog and includes the monitoring client's bundle ID in retained install-only
jobs. Native and authorized remote installation still use the existing pipeline. Self-installation waits for the phone's acknowledgement after ending
the activity. Successful compilation alone never completes installation.
The system activity is submitted only after a running job is accepted; startup
uses a short UIKit lease. The peer-scoped job ID records a single monitoring
attempt across catalog polls, foreground transitions and relaunch. System
expiration or a rejected submission stops background monitoring without failing
the Mac job or automatically creating a replacement activity. Late launches use
the latest confirmed terminal/handoff state, and stale expiration callbacks
cannot stop a newer activity. The monitoring task ends successfully with an explicit **Build monitoring paused**
title on expiration or a peer change. Its completed units describe the ended
monitoring session, not compilation or installation; the Mac job remains running
until confirmed otherwise. Only confirmed failed/cancelled jobs finish the task
unsuccessfully. Terminal activity titles replace stale installation-stage text,
and a failed job takes precedence over any retained self-install handoff.
The progress sheet uses a bounded, centered two-line navigation heading with the
action above the app name. The launch handler attaches the task and its
expiration handler synchronously on the scheduler's main queue. Private
`build_activity` diagnostics distinguish submitted, started, expired and finished
monitoring from Mac build transitions. Handoff clears the expiration handler and finishes
indeterminate progress with explicit completed units before acknowledging install.
Scheduled retained jobs expose their compilation snapshot alongside their durable
installation state, translated by `CodeJob.targetStatus` for the same UI.
Retained artifacts remain available for phone refresh, retries and reconciliation.

Build work comes from bounded, incremental `xcodebuild -resultStreamPath` events:
command sections open/close to update running/completed counts and the operation.
The stream does not supply a reliable total task count. Orbit therefore shows
live work counts with an indeterminate indicator during builds; it does not divide
by a previous build's workload or advance progress based on elapsed time. Apps,
Project, the console summary and the system activity share this behavior. Legacy
companions without events show the last stage and wait for updates. Internal
stage markers advance only at confirmed boundaries. Only confirmed job success
shows 100% in Orbit’s build screen; ending a monitoring session does not change
that job or confirm installation.

Orbit's detached checkout resolves its bundle prefix, exact phone bundle ID and
team from the original ignored `Config/Local.xcconfig`, overriding stale catalog
values. Only those validated settings enter a private ignored checkout config;
source stays committed and the source checkout stays intact. Other projects keep
their own signing rules. `ORBIT_IOS_BUNDLE_IDENTIFIER` defaults to the existing
prefix-plus-`.ios` convention; an explicit local value preserves an existing
phone app's exact identity and controls extension IDs and shared Keychain access.
The Mac ID stays prefix-plus-`.mac`. The setup wizard creates local config only
inside its private extracted source; source/developer checkouts own theirs.
Before a manual or scheduled catalog build, Host restores a missing local config
for legacy bundled source only when the source matches saved setup inside the
private `PhoneSource` directory and setup, catalog and configured phone identities
agree. It validates the restored values with the same self-build validator,
preserves an explicit phone bundle ID, writes owner-only permissions and never
overwrites an existing config or follows a symlink outside private source.
Missing or conflicting saved identity cannot manufacture a replacement identity.
For a source-installed Mac companion, its pinned `OrbitSourceRoot` takes precedence
over old wizard snapshots. Host reconciles private bundled-source Orbit targets to
that checkout's validated local prefix/team/exact phone ID before creating the
build service, retaining target IDs, devices, schedules and job history. Success
for a different bundle is cleared. Active targets are never silently rebound.
The wizard uses the canonical source too and carries explicit phone IDs through
setup. Detached phone builds also copy the two ignored generated native archives
from the canonical checkout, preserving framework symlinks; committed archives in
bundled snapshots take precedence. Both device compilation and retained-artifact installation compare Orbit's
actual bundle ID with the configured phone ID and, when present, the requesting
client's bundle ID. A mismatch produces a durable failure before installation.

Known Xcode signing failures are summarized from bounded startup and tail log reads. Capability/profile mismatches lead the durable job failure shown by Mac, phone and CLI/MCP. App Groups and Time Sensitive Notifications have specific recovery copy that includes embedded extensions. A generic “No Accounts” error directs users to check target/team provisioning without assuming they signed out. A correlated missing-token diagnostic explains that command-line signing can be unavailable while the account still appears signed in; only an explicit expired-session error prescribes signing in again. Unrelated account warnings do not replace a compiler failure. Summaries contain fixed recovery copy; raw account names, project paths and repository output remain in the job log. Orbit preserves the requested entitlements and leaves account authentication and profile updates to Xcode.

## Client diagnostics

`OrbitDiagnosticsKit` (re-exported by OrbitCore) owns process-shared, locked, owner-only JSON-lines
journals: four 1 MiB files per client or received phone. Events carry a UUID,
wall-clock timestamp, session, optional writer sequence, category, name and bounded metadata. Rotation,
restart reads and UUID deduplication preserve acknowledged-batch recovery.
Metadata excludes form/document text, RPC bodies, keys, Apple sessions and the
private installer transcript. Error strings additionally redact credential
assignments, URLs, email addresses, private paths and long token-like strings.
Callers must still avoid supplying secret data; this is structured diagnostics,
not a capture of arbitrary console output.

The iOS window observes controller changes and touch endings without reading
view contents. App lifecycle, navigation, Apps refresh/build actions and RPC
attempts/results/errors are recorded explicitly. Mac lifecycle, clicks, tab/setup
changes, setup actions, local control calls, Code operations and Host job-state
changes feed the Mac journal. Existing build consoles and recovery journals stay
separate. A process-local registry prevents independent UI/Host writers from
racing rotation of the same files.

Every foreground sync pass sends at most four batches of twelve events over
`diagnostics_upload`. Only authenticated trusted peers can upload, and each
canonical phone identity gets its own validated directory. The Host limits
batches to 128 KiB/128 entries, sanitizes again and acknowledges the final UUID
after writing. The phone persists a per-Mac cursor only after that acknowledgement;
lost replies retry safely, including across restarts. If rotation removes a
cursor, synchronization resumes from the oldest retained event. The phone keeps
its journal after upload. Background delivery is opportunistic, and offline
history is bounded by rotation. Upload requests exclude their own RPC trace to
avoid a log-feedback loop.

The local-only `diagnostics` RPC and shared CLI/MCP expose recent Mac events,
paired phone IDs and per-phone received events. Remote peers cannot read either
journal or supply filesystem paths. Logs are untrusted diagnostic data when
read by an agent.


## Installed-app diagnostics

The canonical dependency-free journal and app instrumentation live in
`Sources/OrbitHost/Resources/AppletHost/Diagnostics`, compiled as
`OrbitDiagnosticsKit` and copied into standalone exports. OrbitWidgets shares
that journal implementation. Hosted applets write through the Orbit client
journal; standalone hosts write their own fixed Application Support journal.
Applet hook starts/results and bounded `ctx.debug` breadcrumbs correlate by
invocation, session and source digest without inputs or exception messages.

`OrbitAppDiagnosticCollector` belongs to Host and runs independently from schedule
and script scans. It selects only confirmed `CodeService.installedApps` evidence,
serves one eligible app per ten-second pass, and backs off failures for a minute.
Transport is native CoreDevice container copying in OrbitMac, using the existing
Xcode resolver, exact physical UDID check and device-install lock. It reads four
fixed files with bounded command timeouts into private temporary storage, never
launching an app or treating RPC connectivity as native access. Mac imports bound
file/line/batch sizes, sanitize metadata, ignore incomplete final lines, and
retain UUID deduplication across restart. Per-session writer sequences restore
source order when rotation races a container copy. Per-device/bundle hashes isolate stores;
persisted collection state exposes freshness and unavailable instrumentation or
native access. Control RPC does not gain a phone-to-app filesystem endpoint.

The Mac-local `app_debug_setup` RPC returns the bundled Swift sources for agent
integration; `diagnostics` lists collected app IDs/status and accepts an `app`
selector. CLI and MCP share these methods. The automatically discoverable
`orbit-debug` plugin skill instruments app screens/actions/operations by default
when creating source for Orbit deployment, with no app-side export action or AI
runtime dependency. Existing arbitrary binaries still need a source update.
See [app debugging](app-debugging.md) for APIs, privacy and availability limits.

The Mac app’s About menu reads its bundle ID from the running app bundle, so independently installed copies can be identified during setup or normal use.


## Registered Mac applications

`OrbitTarget.mac` optionally retains an `OrbitMacDeployment`; old catalogs remain
iOS targets. Mac targets use `host-mac` as their destination, no provisioning
lifetime policy and the same catalog, build/job/cancel RPCs, schedule cadence and
GitHub-only source fetch rules. The Mac Add App view accepts Xcode app schemes
and SwiftPM executable products. Paired phones monitor these jobs through
`CodeJob.targetStatus` without running phone-network or refresh-cache workflows.

`OrbitMacTargets` coordinates a bundled standard-library Python worker under
Host resources. Registration requires the existing explicit source-trust flag
before Xcode/Swift package inspection. The worker resolves a running or installed
app, pins its canonical destination, bundle ID, leaf certificate SHA-1 and
designated requirement, and refuses ambiguous copies/certificates. New apps use
user-owned identifiers and `~/Applications`. Orbit self-updates stay on the
existing dedicated worker so ignored local configuration and installed revision
handshake cannot be bypassed by generic target registration.

Before dispatch, the Host persists a job ID in the catalog, then private config
and status journals in `MacTargets/<job-id>/`. The detached worker survives Host
restart and takes a cross-process Mac-target build lock. It builds only the
configured committed revision in a detached worktree, with a separate stable
per-project/product cache. Xcode uses the native Mac destination and signing
settings; SwiftPM static executable apps receive a native .app wrapper, resource
bundles, retained Info.plist/entitlements and certificate signing. The source
checkout, index, user preferences, app support storage and Keychain are untouched.

Before stopping the installed app, the worker verifies deep/strict signatures,
bundle ID, exact certificate and the original designated requirement on the
replacement and current installation. A same-volume transaction keeps a complete
rollback bundle; installed executable SHA-256 readback and (when requested) a
running process at the exact destination are required before success. Failed
launch restores/reopens the previous bundle. Installation/launch phases reject
cancellation. Build cancellation signals only the isolated worker group.

A dead worker before replacement becomes a durable failure; during replacement,
status confirms only a matching installed executable and requested running
path. If a crash leaves only a verified rollback bundle, it restores/reopens
the original and records failure so a new build can be requested. Unconfirmed installation remains `unknownCompletion`, retaining transaction
files and blocking schedule success or automatic retry. Later status reads retry
that verification. Mac jobs never create phone installation/profile evidence.

## Last-known phone page state

Apps restores private UserDefaults snapshots of the target catalog and Mac update
status synchronously on appearance, then refreshes both reads concurrently. Only
successful replies replace snapshots, including empty catalogs. Snapshots are
scoped to the paired Mac ID; a different or removed peer never displays them.
Job/installation evidence still comes from live durable-job reads.

The iOS Apps controller uses a compositional collection layout: full-width Mac
update/search/message rows and an adaptive grid of absolute 160 × 220-point
cards. The column count changes with the viewport; card dimensions never do.
Each shared `OrbitTargetCard` keeps its icon at 60 points, reserves
space for live progress and bounds the name/footer independently of text size.
Errors appear only as a red accessible issue button in the grid. Rejected build
requests keep their message in peer-scoped presentation state until a retry;
Wi-Fi preflight retains its connection guidance alert. The age uses
Host `lastSuccess` (JSONEncoder reference-date seconds), so failed or pending
installs cannot replace the last confirmed success. Missing dates show a dash;
future clock skew clamps to now. VoiceOver reads the relative last-build time
and each Play action names its app.

Selecting a card or its issue button opens `OrbitTargetDetailController` through
a custom UIKit frame expansion from the current visible cell, with a fade for
Reduce Motion or an unavailable origin. The presentation frame stays 12 points
inside all safe-area edges, including after rotation. The icon remains 60 points.
A compact horizontal header makes room in short landscape windows. Refresh
settings, caching and icon-only removal/log/cancel actions remain outside the
bounded scrolling status text; the surrounding card never scrolls. Schedule
changes use the existing Host RPC (six days remains the default). The expanded
card receives the same catalog/monitor updates as the grid, and errors preserve
the text's scroll position when its contents have not changed. Build progress,
logs and action alerts present from the expanded controller when it is open.
Removal requires confirmation and peer/catalog changes dismiss stale details.

Registered Mac apps use the installed bundle’s `CFBundleIconFile` for 132px catalog thumbnails. Registration and background catalog polling populate missing icons and refresh changed artwork at most once every five minutes. The same persisted PNG travels to Orbit Mac and iOS; missing or unreadable icons leave the target available.
