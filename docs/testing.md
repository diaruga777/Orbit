# Testing

## Reproducible local checks

Run `scripts/bootstrap.sh` first. It generates `Vendor/OrbitNet.xcframework` from this checkout (Mac arm64/x86_64, iOS arm64, Simulator arm64/x86_64). The XCFramework is ignored by Git. CGo compilation flags distinguish each Apple platform in Go's build cache.

The macOS `COrbitNet.framework` slice uses the versioned macOS framework layout:
its binary, headers, modules and `Resources/Info.plist` live under `Versions/A`,
with the standard `Versions/Current` and top-level binary/resource symlinks.
Its Info.plist stays under the versioned Resources directory; a root-level
Info.plist symlink is rejected by strict macOS code-signature verification. iOS and
Simulator framework slices keep their flat platform-native layout. Xcode rejects
a flat framework when validating the macOS client.

```sh
swift test
python3 -m unittest discover -s Tests/Python -v
go -C Transport/Go test -race -count=1 ./...
go -C tools/apple-adapter test -race -count=1 ./...
go -C tools/apple-adapter vet ./...
xcodebuild -project Orbit.xcodeproj -scheme Orbit \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/OrbitDerivedData build
scripts/build_and_run.sh --build-only
```

For Mac menu bar icon changes, inspect `OrbitMenuBarIcon.image` at 1x and 2x
for the laptop/phone silhouettes and open orbit, and verify it remains an AppKit
template image. Build and relaunch the committed Mac client with the canonical
script, then check the icon and Open/Quit menu in light and dark menu bars.
An offscreen render checks the artwork; live menu bar acceptance needs an unlocked
Mac.

For app-icon changes, regenerate the project with XcodeGen and verify the iOS
build contains `Assets.car` and declares `CFBundleIcons` / `AppIcon`. Also build
the `OrbitMacBuild` native Xcode scheme and check its icon metadata. The script-built Mac
bundle must declare `CFBundleIconFile = Orbit.icns`, contain that ICNS with all
16–1024px representations, and still pass `codesign --verify --deep --strict`.
Inspect both artwork masters and small-size exports. Home Screen and Dock visual
acceptance is separate from asset compilation and packaging checks.

App-icon verification (2026-10-28): bootstrap ran in a committed detached
checkout. All 165 Swift tests passed (four optional fixtures skipped), as did
14 Python tests, both Go race suites and helper vet. The iOS Simulator build
passed with compiled assets and iPhone/iPad primary-icon metadata. The packaged
Mac app passed signature verification; its declared ICNS round-tripped all ten
16–1024px representations, and the packaged phone-source fixture passed.
Both masters were inspected at 128px, and dimensions/opacity were checked for
every export. The Mac Xcode scheme compiled its icon catalog and signed its app
after separating the app/library target names; final product validation remains
blocked by the existing flat macOS `COrbitNet.framework` layout (Xcode requires
`Versions/Current/Resources/Info.plist`). No physical-device access, Apple sign-in,
Home Screen/Dock acceptance, public notarization or marketplace listing was done.

Monochrome icon revision (2026-10-28): inspected the white silhouettes, thin
tapered orbit gaps and solid black background at 128px. All eleven PNG exports
passed dimensions/opacity checks. Bootstrap, 165 Swift tests (four optional
fixtures skipped), 14 Python tests, both Go race suites and helper vet passed.
The iOS Simulator client built with the revised compiled icons; the Mac asset
catalog compiled directly with `actool`. The packaged Mac app passed signature
verification, all ten ICNS representations round-tripped at 16–1024px, and the
packaged phone-source fixture passed. The previously documented Mac Xcode
framework-validation limitation is unchanged. No physical-device installation,
Home Screen/Dock acceptance, public notarization or marketplace listing was done.

Swift tests cover document version/conflict handling, SourceKit jobs, detached checkouts, target cadence/restart persistence, trust, framing, exact device readback and retained installation evidence. Python tests exercise the stdio tool contract and real fragmented Unix-socket replies. Go tests exercise TLS identity, framing, relay protocol and synthetic Apple installation exchanges. Optional integration tests skip unless their fixture tools are explicitly supplied.

`CodeBuildCatalogTests` checks that a local iOS workspace without Git uses its
original path, preserves local files on cleanup, and records no commit. It also
checks that a malformed Git worktree marker fails and that a dirty editor branch
still builds the selected commit in a detached worktree. A generated-package
fixture prepares an ignored nested Swift package before Xcode would run,
verifies the committed recipe wins over editor changes, and checks cleanup and
console output on hook failure. A replay of Xcode's missing-package diagnostic
checks the short summary and the full path in the job console.

`OrbitHostTests.testTargetIconsBackfillOlderCatalogAndSurviveRestart` covers legacy target icon migration, wire encoding, persistence and throttled lookup failures. `CodeEditorUITests.testTargetListDisplaysIconsAndMissingImageFallbacks` exercises the actual Apps controller with a thumbnail, absent image and invalid image; its screenshot attachment supports visual review without pairing a phone.

Build-catalog tests cover legacy install-only defaults and per-scheme launch
preferences surviving discovery and cache reload. The Simulator build fixture
rejects Play requests with an unexpected `installOnly` value.
`CodeEditorUITests.testLaunchAfterInstallIsPerSchemeAndPersistsAcrossDiscoveryAndRelaunch`
checks launch opt-in, persistence and independence between schemes sharing a
bundle ID. The existing background/startup tests exercise default install-only
requests after leaving Orbit. These fixtures never install on a physical phone.

The Simulator local app picker fixture checks project titles and full paths,
cached rows during a delayed rescan, preview requests for new paths only,
immediate scheme reading, and progress until the Mac returns the new app.
The Simulator removal fixture opens an active build’s app card and checks that
confirming removal returns to the updated Apps catalog.
`OrbitHostTests.testRemovalCancelsDurablePendingAndRetainedBuildsAndIgnoresStaleJobs`
checks retained and pending cancellations, stale and failed job cleanup,
idempotent removal, and continued access to the durable job after removal.

## SourceKit with a real disposable Xcode app

`scripts/test_code_intelligence.sh` generates a UIKit fixture with a local package, builds it for Simulator and checks real SourceKit completion/diagnostics with unsaved edits. It leaves the fixture source unchanged and never launches an app or contacts a phone.

## Private relay and synthetic Apple endpoint

```sh
git clone --depth 1 --branch v1.29.7 https://github.com/syncthing/syncthing.git /tmp/orbit-relay-source
go -C /tmp/orbit-relay-source build -o /tmp/orbit-strelaysrv ./cmd/strelaysrv
ORBIT_TEST_RELAY_BINARY=/tmp/orbit-strelaysrv tools/apple-adapter/integration/run.sh
```

The runner starts a private loopback relay with public pools, NAT traversal and status disabled, then connects the production TLS/stream broker and pinned helper to a synthetic Apple service. It checks successful readback, lost replies, wrong UDID and wrong certificate. It never reads real pairing records or installs an app on a phone.

For client layout checks, inspect the Mac setup fixture at its default size and the smallest supported window. On iPhone check the widget preview and build status in landscape and with larger text. In the share extension, import a script requesting several websites and verify that the review scrolls while Add and Cancel stay visible. In More, check both the animated navigation to Refresh and the direct route from a notification.

## Mock Mac setup screenshots

Run `scripts/capture_setup_screenshots.sh` to capture the complete Mac wizard
without Apple sign-in, phone discovery, installation, networking or setup-state
writes. It compiles the current `OrbitSetupView` and setup value types with inert
fixture models into a separate accessory utility. The only view substitution is
the disk-image path check, so the initial Install Orbit Mac screen can be shown
without mounting a DMG. Continue enablement is extracted from the actual model.

The 13 PNGs, browsable `index.html` and `manifest.json` go to `dist/setup-screenshots` (or the directory
passed as the first argument). They cover the six steps, DMG installation, missing
tools, first launch, private installer sign-in, detected accounts, and mock
installation progress and success. All account/device/pairing values are fictional. Captures show the
wizard content at 1000 × 740 points in light appearance, without window chrome.
They are visual fixtures, not physical acceptance or proof of installation.

## Physical acceptance

`OrbitLegacyIdentityTests` reproduces a legacy bundled source with no local config,
restores its saved identity, and verifies a detached checkout uses committed source
while preserving editor changes. It also covers exact phone bundle IDs, owner-only
config permissions, existing configs, missing/mismatched saved state, source/config
symlinks, and rejection by the real Host build RPC before work is submitted.
These fixtures never access a phone or Apple account.

`OrbitCanonicalIdentityTests` covers a stale wizard target whose identity agrees
with old setup but differs from the canonical checkout, including an exact bundle
ID unrelated to the prefix. It checks Host catalog/config repair, unchanged local
config, wizard source selection, active-job refusal, rejection of requests from a
different Orbit instance and durable rejection of a retained wrong-bundle artifact
before artifact access or installation. Other apps may still be built from Orbit.

Canonical identity verification (2026-11-03): all 243 Swift checks completed
without failures (six optional fixtures skipped), and all 48 Python checks passed.
The detached-checkout fixture also verified native archive copying and relative
framework links. The iOS Simulator app built and its actual Info.plist bundle ID
matched the canonical local config. The Mac review bundle passed strict signature
verification. Physical phone replacement and removal of any duplicate app remain
separate from these checks.

Legacy identity verification (2026-11-03): bootstrap generated the native
dependencies from committed detached source using the installed full Xcode.
All 238 Swift checks completed without failures (six optional fixtures skipped),
all 48 Python checks passed, and both Go race suites plus helper vet passed.
The iOS Simulator client and complete Mac review bundle built with the ignored
local identity. Strict Mac signature verification and the packaged source
extraction/resume fixture passed. No physical phone access, Apple sign-in,
installation/renewal, public notarization or marketplace acceptance was tested.

Before treating a release as verified for unattended personal use, test using the intended Xcode/account/phone:

- First installation with a free Personal Team, then profile renewal before seven-day expiry; verify the installed profile's new expiration and extensions.
- Scheduled install while the Mac is awake and iPhone is available; confirm the exact installed bundle/version/build.
- Mac/app restart, queued job recovery, missing phone, a locked phone, network change and signing failure.
- iOS Play with Launch After Install off: lock after the Mac accepts the build,
  confirm installation over native USB/Wi-Fi, and verify the app stays closed.
  Enable it for that scheme and verify launch while unlocked. Check other
  schemes keep install-only behavior, including aliases for the same app.
- Local Wi-Fi and chosen remote pipe; explicit phone authorization, foreground and iOS-controlled background readiness, peer revocation and refusal to self-replace the active forwarder.
- Updating Orbit through an independent native Apple connection; preserving drafts and app identity.

No WebDriverAgent is allowed on a physical phone. Simulator compilation, synthetic Apple protocols and GitHub CI do not substitute for this acceptance. Marketplace acceptance and Apple account setup are separate manual workflows.

## Extraction verification (2026-10-21)

Local verification used Xcode 26.2, Go 1.26.4 and an iOS 26.2 Simulator:

- 108 Swift tests passed. The real SourceKit fixture enabled both otherwise-skipped intelligence checks; only the separate private-relay fixture was skipped in that run.
- The private-relay/Apple-protocol fixture passed separately using the production transport, scoped stream broker and helper.
- Seven Python MCP/plugin-packaging tests and both Go race-test suites passed.
- The iOS client and UI-test runner built; standalone Mac setup/app navigation, project selection/restoration and save-conflict recovery all passed on Simulator.
- The complete Mac app bundle built and passed signature verification. Its running local service answered CLI status, target listing, GitHub search and Xcode-project inspection.
- Plugin manifest/MCP JSON validated against the published Agent Plugins schemas; both bundled skills passed validation and the plugin launcher completed MCP initialization.
- Luna Mac's remaining 13 tests and Luna Vault's Simulator build passed after removal of Code services.

Mac window visual inspection was unavailable while the screen was locked. No physical phone, Personal Team renewal cycle, unattended background installation or public marketplace acceptance is claimed by these checks.

## Wizard, phone refresh and widget integration (2026-10-21)

The expanded suite covers the cached-build export/refresh policy, IPA traversal
and pairing validation, metadata-before-execution, exact-host HTTPS grants,
JavaScript hooks/timelines, layout and K-V quotas, stale update rejection, setup
state, native Developer Mode evidence, and local-only widget deployment.

The real Simulator import test pastes a JavaScript file, reviews the consent,
installs it in the shared Keychain store and renders its native SwiftUI preview:

```sh
xcodebuild test -project Orbit.xcodeproj -scheme Orbit \
  -destination 'platform=iOS Simulator,id=YOUR_BOOTED_SIMULATOR' \
  -only-testing:OrbitUITests/OrbitWidgetsUITests
```

The review DMG’s source payload is checksum-verified and checked for required
sources, native frameworks, background task/WidgetKit metadata and exclusion of
local signing configuration. This integration test extracts the actual bundled
payload, commits its ignored native binaries, checks SwiftPM’s target discovery,
and resumes interrupted setup without creating another source commit:

```sh
ORBIT_TEST_SETUP_BUNDLE='/absolute/path/dist/Orbit Mac.app' \
  swift test --filter OrbitSetupPayloadTests
```

The packaged CLI/MCP launcher was also exercised against the running isolated
Mac host. Go transport/helper race suites, Python CLI/plugin tests, iOS Simulator
build and signed Mac review packaging pass. A desktop visual review was blocked
by the locked Mac. No Apple account sign-in, physical device access, actual
seven-day/self/extension renewal, installed SpringBoard widget refresh cycle,
background reliability, public notarization or marketplace acceptance is claimed.
The review DMG is development signed; release packaging requires Developer ID.

## JavaScript applets

`OrbitAppletTests` covers inert manifests, widget/applet separation, interactive
controls, action inputs, fresh-VM persistence, network denial, failed invocations
and stale-update rejection. `OrbitAppletHostTests` covers local-only queue/export
permissions, independent phone copies, self-contained committed exports and icons.
Python tests cover MCP and CLI export contracts.

Use `ORBIT_TEST_APPLET_EXPORT=/tmp/OrbitAppletFixture swift test --filter
OrbitAppletHostTests.testStandaloneExportIsCommittedSelfContainedAndHasIcon` to
retain a blank exported host. Create a detached worktree from that repository,
then build its `AppletHost` scheme for Simulator.
`OrbitAppletsUITests` imports a file through Paste, checks consent before render,
launches the native applet and taps its action. Run it alongside
`OrbitWidgetsUITests` on Simulator. Use normal Simulator ad hoc signing
(`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=''`), since unsigned app bundles cannot
exercise the Keychain-backed store. To also test the installed standalone host,
set `TEST_RUNNER_ORBIT_TEST_STANDALONE_APPLET` to its bundle ID before running
`OrbitAppletsUITests`. These checks do not establish physical
installation, Personal Team renewal, widget sharing, or marketplace acceptance.
Standalone apps consume a separate development app slot; physical acceptance
must verify the selected icon and dedicated launch on the intended phone.

## Simplified onboarding checks

`OrbitSetupTests` covers migration from the retired steps, stable generated app
identity, Desktop folder defaults/consent, local-only folder configuration, Xcode
team metadata parsing and physical-phone readiness evidence. Team-cache regressions
cover current Xcode account/identifier indexes without certificates, legacy cache
merging, duplicate precedence, Personal Teams and exclusion of unrelated account
data. These fixtures do not sign in to Apple or access a phone. Python MCP tests run
the real loopback HTTP adapter with a synthetic Host RPC and check initialization,
notifications, tools, token/Origin/Host rejection and payload limits.
`OrbitOptionalSetupUITests` checks all four combinations of independent refresh
and remote setup completion, row badges, More's combined badge, navigation,
relaunch and expiry-notification deep links in Simulator. `OrbitConnectionTests`
checks remote completion from saved routes after a LAN pairing, all three remote
providers, persistence, legacy remote pairings, explicit return to LAN, empty or
invalid routes and forgetting the Mac. These checks never configure remote
networking, sign in to Apple or access a physical phone.

`scripts/test_setup_installer.sh` drives a synthetic `/dev/tty` challenge through
the production terminal adapter, checking secure reply forwarding and redaction
without running the real installer.

Installer execution, fresh-Mac Homebrew/Xcode download, Apple sign-in/2FA/security
keys and sudo prompts require separate interactive acceptance; automated checks
never execute those commands. Physical phone/Personal Team install and renewal,
remote installation away from home, public notarization and marketplace listing
remain separate acceptance work.

## Onboarding verification (2026-10-23)

- Bootstrap generated the source-built transport and current Xcode project in a
  detached checkout.
- 136 Swift tests passed with four optional fixture checks skipped. The packaged
  phone-source/resume check passed separately against the newly built Mac bundle.
- Python stdio/HTTP MCP tests, both Go race suites and Apple helper vet passed.
- The iOS Simulator client and complete ad-hoc Mac review bundle built. The
  packaged Mac app automatically started MCP and answered `orbit_status` using an
  isolated empty catalog. No device-discovery command or installer was invoked by
  this runtime check.
- Two Simulator UI tests passed: optional banner destinations/dismissal and the
  existing JavaScript consent/native preview flow. The 13 inert wizard screenshots
  and synthetic interactive terminal probe passed.

Fresh-Mac Homebrew/Xcode installation, Apple authentication, physical installation
and renewal, remote-network installation, public notarization and marketplace
listing were not performed.

## Applet verification (2026-10-23)

The integrated revision passed 142 Swift tests (four optional integration fixtures
skipped), 14 Python tests, both Go race suites and the helper vet check. The
packaged phone-source fixture passed separately. Both Orbit clients and a
self-contained exported host built; the Mac review bundle passed signature
verification. Simulator UI checks passed applet import consent/action, standalone
consent/action/persistence across relaunch, and existing widget import/preview.
Keychain UI checks use local ad hoc signing, without Apple account sign-in.
Physical phone installation, Personal Team lifetime renewal, public notarization
and marketplace listing were not performed.

## JavaScript file import and automatic delivery

`OrbitScriptImportTests` covers content inference, selected-folder copies, catalog
restart, direct folder additions/edits, malformed/oversized/symlink isolation,
phone read-only access, folder changes and preservation of existing user files.
`OrbitScriptInboxTests` covers durable unapproved receipt, unchanged-source
deduplication, per-digest dismissal, peer changes, stale approval rejection and
bounded file reads. Imported fixtures throw if evaluated.

The iOS build includes the native Share extension and its containing-app Keychain
group. Simulator acceptance should check sharing a .js file from Files, cold and
warm Open in Orbit, file selection from either tab, automatic review badges while
connected to a fixture Mac, offline/relaunch recovery, and approval before native
rendering. Physical delivery/background reliability remains separate acceptance.

## Expiry setup reminder

`CodeExpiryReminderTests` covers earliest expiry, exact 24-hour lead time, actual
paid-profile dates, the seven-day fallback, late sync, expired evidence, confirmed
renewals, durable per-device snapshots, legacy wire fields and exclusion of
uninstalled build artifacts. Retained-install backfill uses synthetic journals
and never contacts Apple devices. Simulator navigation checks exercise the same
notification destination with the banner dismissed and Refresh in overflow tabs.

Physical acceptance must separately check notification permission/denial,
background delivery before real Personal Team and paid-profile expiry, tapping
from a terminated app, receipt delivery through CoreDevice, multiple phones,
app removal, and cancellation after setup/confirmed renewal. Simulator and unit
checks do not establish physical delivery, Apple account status or renewal.

Expiry reminder verification (2026-10-23): 149 Swift tests passed with four
optional fixtures skipped; the packaged phone-source fixture passed separately.
All 14 Python tests, both Go race suites and helper vet passed. The iOS Simulator
client and ad hoc Mac review bundle built and the bundle passed signature checks.
Three Simulator UI tests passed, including OS notification delivery while Orbit
was terminated, tapping it into Refresh setup, and navigation with a dismissed
banner. Notification response completion stays on the main thread for UIKit’s
cold-launch scene handling. No physical device, Apple sign-in, actual profile
renewal, public notarization or marketplace acceptance was performed.

JavaScript import verification (2026-10-23): 156 Swift tests passed with four
optional fixtures skipped. The packaged phone-source/resume fixture passed
separately, including Share extension source and entitlements. All 14 Python
tests, both Go race suites and helper vet passed. Both clients built with the
Share extension embedded in iOS; the Mac review bundle passed signature checks.
Four Simulator UI tests passed: durable inbox receipt/relaunch/consent, content
routing across tabs, applet consent/action and widget consent/preview. A disposable
committed UIKit share-host fixture also exercised the real system Share sheet,
Orbit’s extension consent, shared Keychain import and subsequent applet rendering.
The Mac was locked, so Finder drag/drop and desktop visual acceptance were not
performed. No physical phone, Apple sign-in, background-delivery guarantee, public
notarization or marketplace acceptance is claimed.

## iPad window cleanup (2026-10-24)

All six iOS destinations use native tab/sidebar identities, preserving selected
routes and JavaScript review badges. The tab controller is the window root; the
optional setup banner reserves a measured top inset without inheriting that
inset back into its own margins. This keeps rotation and sidebar transitions
under UIKit’s control. Target/job menus anchor to rows and import menus to Add.

Simulator checks on iPadOS 26.2 passed rotation/target menu, sidebar-to-Refresh,
optional setup routing/dismissal and cold-launch expiry routing. A fresh iOS 26.2
iPhone Simulator passed setup/expiry routing and widget content routing from
Applets before consent. No Apple sign-in or physical device access was used.

## Landing page

The static page has no package installation or build step. Run `node --check
website/script.js`, then serve it using the commands in [website hosting](website.md).
Review desktop and narrow mobile widths in both appearances, including the
Apps/Applets/Widgets tabs, Up/Down/Home/End keyboard navigation, FAQ disclosures,
anchor links and release/source destinations. Confirm assets also load under
`/Orbit/`, the document has no horizontal overflow and the console has no errors.
The product UI is an illustration; it is not physical-device acceptance or proof
of an installation. Deployment and notarized DMG publication remain separate.

Landing-page verification (2026-10-25): reviewed 320, 390, 768 and 1280 pixel
layouts with no horizontal document overflow, light/dark appearance, saved theme
restoration, all three feature tabs and Up/Down/Home/End navigation, FAQ expansion
and anchor navigation. Browser console was clean. JavaScript syntax, local
assets, unique IDs, fragment destinations and the SVG parsed successfully; the
`/Orbit/` preview returned HTTP 200. Bootstrap ran in a detached checkout with
isolated `ORBIT_HOME`. The unchanged application sources passed 156 Swift tests
(four optional fixtures skipped), 14 Python tests, both Go race suites and Go vet.
The iOS Simulator client and ad hoc Mac review bundle built; Mac signature
verification passed. No physical-device acceptance, Apple sign-in, public
notarization, live Pages deployment or marketplace listing was performed.

## Applet polling

`OrbitAppletPollingTests` covers inert interval/capability validation, legacy
headers, independent poll hooks, parsing, persistent cadence, restart catch-up,
event-ID deduplication, durable delivery retries, failed-parser/network/output
rollback, backoff, notification consent, changed sources and deletion. Tests use
synthetic JSON and denied hosts; they do not contact internet sources or phones.
The exported-host check verifies background metadata and included scheduler source.

Simulator acceptance should import `docs/applets/examples/release-watch.js`, review
the sites/schedule/notifications before execution, allow or deny system alerts,
inspect saved parsed data, and check notification routing from a cold launch.
Test background expiration, Background App Refresh disabled and standalone source
updates requiring fresh approval separately. Unit tests and Simulator builds do
not establish actual iPhone background cadence, notification delivery, physical
installation/renewal or marketplace acceptance.

Applet polling verification (2026-10-26): bootstrap generated native dependencies
in a detached checkout. All 165 Swift tests passed (four optional fixtures
skipped); the packaged phone-source fixture passed separately. All 14 Python MCP
checks, both Go race suites and helper vet passed. The iOS Simulator client,
ad hoc signed Mac review bundle and committed exported standalone host built;
Mac signature verification passed. Three Simulator UI checks passed: polling
consent/parsing/persistence/cadence, existing applet actions and widget import.
The polling check passed again after the final scheduling safeguards. Fixtures
used synthetic JSON; no live-source availability, physical-device background
cadence, Apple sign-in, actual install/renewal, public notarization or marketplace
acceptance is claimed.

## Xcode account detection (2026-10-30)

Team discovery covers current Xcode team indexes and legacy caches without
requiring a development certificate. A local read-only probe detected the existing
team in about 5 ms without signing in or accessing a phone. All 167 Swift tests
passed (four optional fixtures skipped), as did 17 Python tests, both Go race
suites and helper vet. Both clients built; the complete signed Mac setup bundle
passed extraction/resume and signature verification. The update check accepted
the existing designated requirement and rejected a mismatched identifier.

The native payload packager preserves relative versioned-framework links and
rejects links that escape the native archive, absolute paths, missing targets and
cycles. A synthetic framework is extracted with the same macOS tool as setup to
verify its links and contents. Initial concurrent client builds exhausted disk
space; temporary outputs from this run were cleared and the builds then passed.
The existing Mac review app was updated in place with its bundle ID and
certificate preserved. The running wizard showed its detected account,
“Your Apple Account is ready” and an enabled Continue button. It was left on the
account screen. No Apple account sign-in, physical installation/renewal, public
notarization or marketplace acceptance was performed.

The full Swift suite passed again after making packaged applet export independent
of the build directory. The running signed app exported a complete committed
fixture with its build resource bundles hidden. A final optional payload recheck
could not compile after Xcode 26.2 was removed and the selected developer directory
changed to standalone Command Line Tools; its C++ compiler could not find
`<string>`. The earlier payload extraction/resume check passed with Xcode 26.2.

## Xcode selection and phone discovery

`CodeXcodeToolsTests` uses temporary executable fixtures to cover standalone tools,
a removed selection, renamed/beta Xcode apps, explicit override precedence and
failure, and preservation of non-Apple command environments. Discovery failure
checks retain the underlying tool error; existing discovery fixtures cover USB,
Wi-Fi, unavailable phones and Simulator exclusion. These tests never discover or
access a physical phone. Local setup discovery and physical installation remain
separate from automated validation.

Phone-discovery verification (2026-10-30): bootstrap, the 170-test Swift suite
(four optional fixtures skipped), 17 Python tests, both Go race suites and helper
vet passed using Xcode 27.1. Both clients built and the packaged phone-source
extraction/resume check passed. The Mac update retained its installed path, bundle
ID and certificate; final signature verification passed after removing obsolete
flat resources left by the old overlay updater. The updater now synchronizes the
verified bundle exactly and verifies the installed copy. A separate interactive
setup check showed the user's iPhone in the picker with standalone command-line
tools still selected. Physical install/renewal and marketplace acceptance are not
established by these automated checks.

## Guided refresh setup (2026-10-30)

Refresh presents the next incomplete account, pairing, certificate, cache or
connection stage with numbered progress and explanatory copy. Setup details
retains import and maintenance actions. Banner controls have a minimum 44-point
height; the dismiss control also has a minimum 44-point width. Phone authorization
uses native challenge delivery and the running client's signing identity rather
than asking the user to choose a phone.

Bootstrap, Python MCP tests, both Go race suites and adapter vet passed. The full
Swift suite passed on retry; the initial run hit an applet VM quota failure,
which also passed individually. Both the iOS Simulator client and ad hoc Mac
review bundle built. No Simulator visual walkthrough, physical phone access,
Apple sign-in, installation/renewal or marketplace acceptance was performed.

## Local project discovery

`OrbitProjectDiscoveryTests` checks project/workspace detection, package boundaries, hidden/cache/dependency exclusion, symlink avoidance, deduplication and scan bounds using temporary inert directories. Manually verify automatic Mac and paired-phone lists, scan retry/offline errors, empty results, native Mac file selection, trust cancellation, multiple iOS schemes and registration. These checks require no physical deployment or Apple sign-in.

Project-discovery verification (2026-10-30): bootstrap completed with the installed
Xcode selected only for validation commands. The 172-test Swift suite passed
with four optional fixtures skipped; all 17 Python tests, both Go race suites
and helper vet passed. Both final clients built, the Mac review bundle passed
signature verification, and the packaged phone-source extraction/resume fixture
passed separately. A read-only home-folder probe found 30 projects, including
Orbit, in about two seconds. Discovery and trust fixtures use inert temporary
folders and never access phones. Interactive Mac/iOS picker acceptance, physical
installation/renewal, public notarization and marketplace listing remain separate.

## Live remote connection setup

`OrbitConnectionTests` covers live activation before configuration persistence,
activation failure rollback, local/remote transitions, authenticated route exchange,
per-transport pins, confirmed phone enrollment before persistence, alias ownership and collision rejection, restart persistence,
revocation, backwards-compatible configuration and Tailscale/relay validation.
Fixtures use inert addresses and injected listeners; they never contact a phone,
Apple account, public discovery or a relay service.

The iroh-to-Tailscale regression check starts with an iroh-only pairing, enrolls
its TCP alias through route sync, then checks that the phone is still trusted
after changing providers and receives the pinned Tailscale address before Wi-Fi.

Interactive acceptance: open **Orbit Mac → Settings** and verify the same picker
also appears in **Phone & Remote Setup**. With the updated iPhone app open on the
same Wi-Fi, sync an iroh pairing, select Tailscale, paste the Mac’s Tailscale IP
or MagicDNS name, and apply. Confirm the phone updates and **More → Mac** shows
**Tailscale**, then use **Check Connection** and load Apps from a second Wi-Fi
network on the tailnet. Verify offline-phone catch-up, both clients restarting,
local Wi-Fi fallback, switching back to local-only, and errors for malformed
Tailscale and private-relay addresses. Existing Apple installation authorization must
survive transport changes. Internet reachability and physical installations need
separate physical acceptance; unit tests do not establish them. The synthetic
reverse-flow byte/half-close/replay check also covers iroh readiness. Active phone
forwarding restarts when route snapshots change and resolves the current pinned
route for each Apple stream.

Tailscale settings verification (2026-11-15): bootstrap, 252 Swift checks
(seven optional fixtures skipped), 48 Python checks, both Go race suites and
Apple-helper vet passed. The iOS Simulator and native `OrbitMacBuild` builds
passed with the local identity configuration. Both targeted More settings UI
tests passed in Simulator. The Mac review package passed strict signature and
packaged phone-source extraction checks. Live tailnet connectivity and Apple
installation on a physical phone remain separate acceptance checks. No
marketplace listing was performed.

Remote-setup verification (2026-10-30): bootstrap ran in a detached committed
checkout. All 177 Swift tests passed (four optional fixtures skipped), plus
17 Python MCP tests, both Go race suites and helper vet. Both Xcode client builds
passed using the ignored local signing configuration. The complete Mac review
bundle retained the running app’s signing certificate and passed signature and
packaged phone-source extraction/resume checks. Its isolated running service
switched local → iroh → local twice without restarting; each activation returned
ready status. The normal app and its state were left intact. Inert captures of
the actual Mac setup views covered local, iroh, Tailscale, private relay and
startup-error layouts with connection options expanded. No physical phone,
Apple sign-in, away-from-home handoff/install acceptance, public notarization or
marketplace listing was performed.


## Mac Add App

`CodeProjectPreviewTests` exercises inert app detection, library/test/extension/
Mac exclusions, explicit Run aliases, metadata edits, canonical app choices with alternate schemes, branch defaults and nested
workspace references without Xcode or devices. Catalog tests also reject an
automatic library scheme whose build settings include an app dependency.
Desktop acceptance should check cached previews on entry/relaunch, rescan,
project switching during preview reads, icons in the app menu, local/GitHub tabs,
phone names/defaults/offline state, collapsed Advanced settings, validation
progress/errors, and successful/duplicate adds appearing immediately in Apps.
A success banner means registration only; physical installation and provisioning
lifetime remain separate acceptance.
## Refresh sign-in form

`CodeRefreshSignInTests` validates blank/default/custom server selection and
credential validation without networking. `OrbitRefreshSignInUITests` drives the
actual UIKit sheet through an inert Simulator-only service: blank server with
Remember enabled, missing credentials, failed sign-in/retry, invalid custom URL
and clearing it, Apple verification with a rejected code, team-save retry,
verification failure recovery/cancel, cancellation during verification, no signing
teams, and the largest accessibility text during password entry. Screenshot attachments capture the form and verification states.
The fixture never authenticates with Apple, contacts anisette services, reads
refresh secrets or installs on a phone. Real account sign-in and renewal remain
separate physical acceptance.

Refresh sign-in verification (2026-10-30): bootstrap generated transport/native
sources in a detached committed checkout. All 179 Swift tests passed (four
optional fixtures skipped), along with 17 Python MCP tests, both Go race suites
and helper vet. Both clients built with the ignored local identity configuration;
the separate ad hoc Mac review bundle passed signature verification and its
packaged phone-source extraction/resume fixture passed. All nine final Simulator
form tests passed. The first form iteration missed a tap while the keyboard and
scroll position changed; fixing Sign In above the keyboard resolved that check.
Reviewed the default form, error, Apple verification and largest-text captures.
A credential-free request to the default helper’s v3 metadata endpoint succeeded;
this does not establish Apple account authentication. No Apple sign-in, physical
installation/renewal, background acceptance, public notarization or marketplace
listing was performed.


## Mac pairing-file export

`OrbitPairingExportTests` uses inert local executables to check missing/non-runnable
helpers, missing phone selection, exact selected-phone arguments, independent
private exports and cleanup after helper/permission failures. Go CLI tests inject
synthetic readers to check trust recovery, sanitized diagnostics, bounded export,
0600 creation and refusal to overwrite. No test reads an actual pairing record.

After building each Mac app path, set `ORBIT_TEST_PAIRING_APP` to that bundle and
run `swift test --filter OrbitPairingExportTests`. This checks the embedded helper’s
signature, dependency notices and invalid-argument recovery before any daemon
access. Also verify the enclosing bundle signature. Physical export, manual
AirDrop/import and LocalDevVPN renewal remain separate acceptance steps.

Pairing-export verification (2026-10-30): bootstrap generated the native transport
in a detached committed checkout. All 184 Swift tests passed (five optional
fixtures skipped), plus 17 Python MCP tests, both Go race suites and helper vet.
The final iOS Simulator client, native arm64 Xcode Mac client and complete Mac
package built using the ignored local signing configuration. The helper and
whole bundle passed strict signature verification in both Mac build paths;
optional bundled-helper tests passed for both, and packaged source extraction/
resume passed. Removing the transport framework’s nonstandard root Info.plist
symlink fixed its strict embedded-signature check. An initial universal Mac link
failed on unresolved x86_64 iroh symbols; native arm64 validation passed. Synthetic
helper calls use invalid arguments or injected readers, never real pairing data.
No physical phone export/import, Apple sign-in, installation/renewal, public
notarization or marketplace acceptance is established by these checks.

Mac Add App verification (2026-10-30): bootstrap generated transport in the
committed detached checkout. After integrating current main, the Swift suite
passed all 182 checks (four optional fixtures skipped); 17 Python tests, both Go
race suites and helper vet passed. The iOS Simulator client and separate ad hoc
Mac review bundle built using the ignored local configuration. The Mac bundle
passed strict signature checks and its packaged phone-source/resume fixture.
An inert probe of the actual Luna project returned five primary app choices,
all with icons, in about 75 ms; LunaMusicUI remained an alternate scheme rather
than an extra app. Native captures of the production views with inert models
covered local selection, dark appearance, GitHub, background discovery,
registration progress and the Apps confirmation. Physical registration/install/
renewal, live GitHub download acceptance, public notarization and marketplace
listing were not performed.

After integrating the concurrent Add App changes, all 187 Swift checks passed
(five optional fixtures skipped), along with all 17 Python checks. Both final
client builds passed, as did both Mac bundles’ helper/full signature checks and
the packaged source/resume check. The current Mac app received the missing helper
at its existing path with its signing requirement verified; a concurrent Xcode
rebuild then updated that same path. Its active debug session was left in place.
No real pairing record was exported during validation.

## Refresh setup audit

`CodeRefreshAccountTests` exercises the real account coordinator with in-memory
secrets and injected networking: helper metadata/identity propagation, blob reuse
and invalidation, one same-service recovery for rejected blobs, failed sign-in
and empty teams, legacy migration, atomic write failure, remembered-password
removal, account/team changes, cancellation and overlapping operations. No test
contacts Apple, reads real refresh secrets or accesses a phone. Validation also
checks certificate team/lifetime and profile/signed-entitlement preservation.
The default helper now uses SideStore’s listed Mac ADI service; a credential-free
metadata probe establishes only endpoint availability, not account acceptance.

Refresh-audit verification (2026-10-30): bootstrap generated native dependencies
in a committed detached checkout. All 200 Swift checks passed (five optional
checks skipped), all 17 Python MCP checks passed, both Go race suites and helper
vet passed. The iOS Simulator client and complete ad hoc Mac review bundle built
using the ignored local identity configuration. Strict bundle/helper signatures
and six optional packaging/export checks passed, including phone-source
extraction/resume. All nine final sign-in Simulator UI checks passed. The first
UI run exposed Advanced settings interacting with the keyboard; expanding them
now dismisses the keyboard and reveals the field, and tests identify the form’s
scroll view explicitly. Credential-free metadata requests to both the old and
new helper endpoints succeeded; the new default is the officially listed Mac
ADI service and its identity is propagated into provisioning/authentication.

The audit also fixed lost reusable ADI state, non-atomic account/key updates,
certificate/team mismatches and expiry readiness, overlapping account/connection/
reconciliation/import operations, silent capability changes after signing, file
import access/error presentation, and self-refresh proceeding while merely
inactive. Apple authentication, real pairing export/import, physical install/
renewal, background reliability, public notarization and marketplace acceptance
were not performed or established.

## Apps progress and Orbit identity

`CodeOrbitIdentityTests` rejects missing/sample identities, preserves exact phone
IDs and overrides stale catalog values without changing other projects.
`CodeTargetJobTests` verifies real compilation detail survives Host payloads and
waiting/installing/uncertain jobs stay below completion until installation is
confirmed. The Apps Simulator fixture drives the production controller and shared
monitor through startup, changing progress/task counts, console, dismissed
progress, reconnect and failure/success. It never connects to a Mac, Apple
account or physical phone. Physical Live Activity delivery/background lifetime
and replacing an installed Orbit require separate acceptance.

Build-feedback verification (2026-10-31): bootstrap ran in a detached committed
checkout. All 207 Swift checks passed (five optional fixtures skipped), all 19
Python MCP/configuration checks passed, both Go race suites and helper vet
passed. The iOS Simulator app, native arm64 Xcode Mac app and separate ad hoc
Mac review package built with ignored local identity settings. Built phone and
extension identifiers and their shared Keychain metadata matched the configured
exact phone identity. Both Mac bundles passed strict signature verification;
packaged phone-source extraction/resume passed. Seven Simulator UI checks passed:
Apps progress/console/completion, reconnect/failure, background startup, legacy
progress estimates, actual build task detail, self-update recovery and app icons.
The progress, completion and failure captures were reviewed. An initial standard
cell layout hid the progress bar; the final stack layout and regression checks
cover it. No physical phone access, Apple sign-in, actual installation/renewal,
physical Live Activity delivery, public notarization or marketplace acceptance
was performed.

## Signing failure recovery

`CodeBuildFailureTests` covers simultaneous missing-account and Time Sensitive Notifications profile failures, individual account/capability errors, alternate Xcode wording, unrelated credential warnings during compiler failures, private-detail exclusion and bounded reads of large logs. These fixtures never access Apple credentials, provisioning caches or devices. A successful signed Luna build still requires an authenticated Xcode account and a profile that includes its requested capabilities.

Signing-recovery verification (2026-10-31): bootstrap generated native dependencies
in a committed detached checkout. All 212 Swift checks passed (five optional
fixtures skipped), all 19 Python checks passed, both Go race suites and helper
vet passed. The beta Xcode default Swift Build test runner stalled in an existing
async widget test; `swift test --build-system native` completed the suite, and the
final diagnostic revision passed the same full suite. The iOS Simulator client
and complete development-signed Mac package built with the ignored local identity.
The Mac package passed strict signature and existing designated-requirement checks,
and replaced the idle running client at its existing path with the same bundle ID
and certificate. The restarted local Host answered status with all six targets.
Luna's source and intentional notification entitlement were preserved. Its signed
build remains blocked by the reported missing Xcode account token and profile
capability mismatch until the user repairs Xcode sign-in/signing. No Apple sign-in,
physical-device access, installation/renewal, notarization or marketplace acceptance
was performed.

## Apps RPC delivery and client logs

`OrbitRPCDeliveryTests` sends a 3 MiB catalog-sized response over real local QUIC
using the production iroh stream and framing, with discovery/relays disabled.
It verifies that server teardown waits for the client's complete read and close.
`OrbitDiagnosticsTests` covers concurrent writers, bounded rotation, privacy
redaction, owner-only permissions, cursor recovery, restart deduplication,
authenticated per-phone upload, local-only reads, oversized batches and invalid
phone/path rejection. It uses temporary state and synthetic identities.

`CodeEditorUITests.testAppsBuildShowsLiveProgressConsoleAndCompletion` starts the
production Apps build flow using its one-press play button.
`testAppsListFailureCanRetryAndEmptyCatalogExplainsAdd` covers a failed list read,
Retry and an empty catalog. Existing progress, reconnect and failure checks use
inert build jobs; no Simulator fixture builds or installs a physical app.

Physical acceptance should additionally check a real paired phone's Apps list,
one play press, exact installed revision/profile lifetime, relaunch/network
changes, and phone log arrival on Mac after an offline interval. Automatic
foreground log transfer does not imply delivery while iOS suspends the app.
Apple account repair, physical installation/renewal, public notarization and
marketplace listing remain separate acceptance.

Apps/logging verification (2026-10-31): bootstrap generated native dependencies in
a committed detached checkout. All 216 Swift checks passed (five optional checks
skipped), all 19 Python checks passed, both Go race suites and helper vet passed.
The local QUIC test failed with `ORBIT_TEST_IMMEDIATE_CLOSE=1`, reproducing the
historical truncated reply, and passed with normal reply draining. The final iOS
Simulator client, native arm64 Xcode Mac client and complete Mac package built
with the ignored local identity configuration. Strict Mac signatures and six
packaged helper/source extraction/resume checks passed. Three final Simulator
checks passed: one-press Play/progress/console/completion, reconnect/failure and
list failure/Retry/empty state. Reviewed the progress, completion/play and failure
captures and confirmed the Simulator's private 0600 journal contains lifecycle,
screen, interaction, Apps/build and RPC events.

The first iOS build caught a duplicate lifecycle callback and a window property
name collision; both were corrected. The first Retry fixture raced automatic
polling; injecting its polling interval made explicit Retry deterministic. Inert
Simulator previews now skip production foreground networking even if the
Simulator had a saved pairing. The running Mac client was updated at its existing
path using its existing certificate, bundle ID and verified designated
requirement; its local control socket exposes the retained six-target catalog
and new diagnostic reads. iPhone installation, live physical log transfer,
provisioning renewal, Apple sign-in, notarization and marketplace acceptance were
not exercised by these checks.


## App and applet diagnostics

`OrbitAppDiagnosticCollectorTests` uses injected journal files, never a phone. It
covers unavailable/backoff/reconnect behavior, order, duplicate reads after
restart, per-phone/bundle isolation, metadata redaction, partial-line replay,
malformed-event rejection, file/batch bounds, packaged-resource lookup and
Mac-only source/read access. The applet breadcrumb test
executes the real JavaScript runtime to check correlation, ordering, the 32-event
quota and omission of input/error strings. Export tests require the canonical
helper sources in the self-contained committed project. Python MCP checks cover
the app selector and read-only source setup tool.

For source integration, retrieve `orbit_debug_setup`, add all three Swift files
to an iOS target and build on Simulator. Exercise a screen, action and caught
failure; inspect its `Library/Application Support/OrbitAppDiagnostics` journal.
A standalone applet export should build without importing Orbit packages.
Physical acceptance is separate: install an instrumented committed app through
Orbit on the intended phone, interact, verify automatic Mac collection and
freshness, disconnect/reconnect and restart the Mac, then check ordered replay
without duplicates. Check lock/unavailable-container behavior and instrumented
versus uninstrumented apps. No unattended test accesses physical devices, signs
in to Apple, establishes marketplace readiness or proves background delivery.


App diagnostics verification (2026-10-31): bootstrap generated the source-built
transport in a committed detached worktree. All 221 Swift tests completed with
zero failures (five optional fixtures skipped), along with 19 Python tests,
both Go race suites and Apple-helper vet. The `orbit-debug` skill passed its
skill validator. The iOS Simulator client, packaged Mac client
and self-contained standalone applet export built successfully; the Mac review
bundle passed `codesign --verify --deep --strict`. Tests exercised the real
JavaScript breadcrumb API and synthetic app collection/recovery. No physical
phone access, Apple sign-in, physical UI acceptance, public notarization or
marketplace listing was performed. Real native container copying and phone
lock/reconnect acceptance remain manual checks on the intended hardware.

## Mac bundle identity

Open **Orbit Mac → About Orbit Mac** during setup and after setup. Verify the selectable bundle ID matches the running app bundle’s `CFBundleIdentifier`, including for independently installed copies.


## Canonical Mac builds and self-update

Python Mac-update tests cover exact leaf-certificate selection, same-team key
rejection, ambiguous first installs, detached committed source with staged and
working edits preserved, fragmented production local RPC framing, signing failure
before stopping the app, exact bundle replacement, rollback and durable exclusive
jobs. Swift tests cover maintenance gating, status across restart, interrupted
workers and trusted-peer restrictions. Simulator fixtures cover the separate Mac
section, rebuild request, reconnect, failure/log and empty Apps behavior.

Run the regular suite above in committed detached source, then check both paths:

```sh
xcodebuild -project Orbit.xcodeproj -scheme OrbitMacBuild \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/OrbitMacNative build
scripts/build_and_run.sh --verify
```

The second command updates the actual installed Mac app. Verify one matching
process, canonical bundle path, unchanged certificate/designated requirement,
bundle ID, state root and target/phone IDs. Verify the Xcode product resolves to
the canonical app, the app remains signed after build and Clean Build Folder,
and a failed installer prevents Run from launching an older product.
Xcode's **OrbitMac → Run** should build
the same committed revision and launch that exact copy with debugger attachment.
Exercise a real Mac-initiated update and a paired-phone request separately; a
Simulator fixture establishes UI behavior only. macOS TCC folder permission
acceptance requires the intended logged-in user's session. Physical phone
installation/renewal and public notarization/marketplace listing remain separate.


Canonical-update verification (2026-11-01): bootstrap generated native dependencies
in committed detached source. All 224 Swift tests passed (five optional fixtures
skipped), along with 28 Python MCP/configuration/update checks, both Go race
suites and helper vet. The iOS Simulator client, native `OrbitMacBuild` Mac client,
complete signed package and shared `OrbitMac` installer scheme built. The packaged
phone-source extraction/resume fixture passed. Four Simulator UI checks passed:
Mac update/reconnect, Mac failure/retry/log, Apps list failure/empty state and the
existing phone-app build/progress/completion flow. The separate Mac section and
completion screenshot were reviewed.

Actual canonical Mac installation and the running Host's self-update request
preserved the leaf certificate, designated requirement, bundle ID, absolute state
root, all six existing targets and both paired identities. The reopened app
reported its expected committed revision at `~/Applications/Orbit Mac.app`, with
one matching process; a protected Desktop-folder browse still succeeded. Updates
executed from a primary checkout with existing scheme edits, which remained
uncommitted. The worker survived the old Host's shutdown and persisted success.
Repeated-build testing exposed absolute cached artifact paths; a stable fresh
detached checkout plus explicit scratch path fixed them. The first real GUI-owned
update exposed an inherited Command Line Tools SDK/compiler mismatch; resolving
compiler and SDK from the same full Xcode fixed the live retry. Failure left the
installed app running and retained a durable log.

The Mac was locked, so interactive Xcode Run/debugger and Mac button click-through
remain unverified; the Xcode build/install path and same Host update handler were
exercised. No Apple sign-in, physical phone access/installation/renewal, physical
phone UI acceptance, public notarization or marketplace listing was performed.


## Phone build Wi-Fi preflight

`CodeEditorUITests.testAppsBuildRequiresWiFiBeforeRequestAndCanRetry` drives the
production Apps play button and row menu with an injected unavailable Wi-Fi
probe. It checks the guidance, absence of progress and build requests, enabled
retry, then a successful start after the probe reports Wi-Fi. The fixture does
not change the host network or contact a Mac, Apple account or physical phone.
The existing progress/completion check covers the allowed build flow.

Physical acceptance separately checks cellular-only (including an active remote
pipe/VPN), offline, ordinary Wi-Fi and Wi-Fi hotspots, plus joining Wi-Fi and
retrying without relaunching. Wi-Fi association is a prerequisite, not proof of
Apple-service reachability or installation. No synthetic check establishes
physical installation, provisioning renewal or marketplace readiness.


Wi-Fi-preflight verification (2026-11-01): bootstrap generated native dependencies
in committed detached source. All 224 Swift tests passed (five optional fixtures
skipped), along with 28 Python tests, both Go race suites and Apple-helper vet.
The iOS Simulator client and complete Mac review bundle built with the ignored
local identity configuration. The Mac bundle passed strict signature verification
and six optional packaged helper/source extraction/resume checks. Both relevant
Simulator UI checks passed: blocked play/menu requests and retry after Wi-Fi
becomes available, plus existing build progress/console/completion. Reviewed the
Wi-Fi guidance screenshot. The initial UI assertion expected a literal newline
in an accessibility label; matching its request-count text fixed that test.
No physical phone access, Apple sign-in, actual installation/renewal, public
notarization or marketplace acceptance was performed.

## Xcode canonical Run repair (2026-11-01)

The `OrbitMac` scheme now resolves a native application product linked to the
canonical app, replacing the literal `$(HOME)` PathRunnable. `OrbitMacBuild` and
its native output agree on `OrbitMacClient.app`. Bootstrap and a fresh source
transport build completed in committed detached source. All 224 Swift tests
completed with zero failures (five optional fixtures skipped), all 32 Python
checks passed, both Go race suites and helper vet passed, and the iOS Simulator,
native Mac client and canonical Xcode installer builds succeeded.

Launching the Xcode product through Launch Services reopened exactly one process
at the canonical path with the expected revision. The pinned certificate,
designated requirement, bundle ID and state root were preserved. An actual Xcode
Clean against a product linked to a disposable signed app preserved that app's
signature and contents. A deliberately unavailable certificate failed the Xcode
installer phase and left the existing canonical app running and signed. New
regression checks cover product replacement, missing installation, refusal to
delete unexpected files, clean semantics and product-based Run/Profile schemes.

The Mac was locked, so interactive Play/debugger attachment remains unverified.
No physical-device access, Apple sign-in, phone acceptance, public notarization or
marketplace listing was performed.


## Registered Mac app builds

`test_mac_targets.py` exercises certificate ambiguity and pin rejection, original
designated-requirement checks, unchanged installed bundles on verification
failure, installed executable readback, rollback after launch failure, interrupted
installation reconciliation, cancellation boundaries and private journals.
Inspection fixtures check adoption of a running Swift package app’s path,
identity and privacy metadata. MCP/CLI tests register a Mac target without a
phone and preserve explicit install-only requests. Host tests retain Mac settings
across catalog restart, reject untrusted registration before execution, skip iOS
icon discovery and fail an accepted-but-undispatched build safely.

For live Mac acceptance, register an already paired development-signed companion,
record its path, certificate, requirement and non-secret hashes of its pairing
preferences/transport identity, build through Orbit, and verify the new process
at the same path plus unchanged identity/preferences. Run an independent committed
Xcode Mac fixture too. This is desktop acceptance; it does not establish physical
phone installation, live reconnection while the phone is asleep, Apple account
sign-in, public notarization or marketplace readiness.


Mac-target acceptance (2026-11-01): 227 Swift tests passed (five optional fixtures
skipped), 48 Python tests passed, both Go race suites and helper vet passed.
Bootstrap generated the transport with the installed full Xcode; the iOS
Simulator client and complete signed Mac client built from committed detached
source. The live Host catalog registered Luna Vault’s Swift package, built its
committed main revision, replaced the already-running .app and confirmed a new
process at the original installation path. Bundle ID, exact leaf certificate,
designated requirement, pairing/client preference hashes and transport identity
file hashes all matched the pre-update snapshot. No Apple credentials were read.
A separate committed native Xcode Mac fixture also built, installed and launched
through the same Host RPCs. The fixture was removed afterward; Luna remains
registered for manual builds. The locked Mac prevented visual review. No phone
installation/sign-in, live phone reconnection, distribution notarization or
marketplace listing was performed by these checks.


## Signing session versus extension provisioning

`CodeBuildFailureTests` covers LunaMusic-style Share extension App Groups failures
with a wildcard profile and simultaneous `No Accounts`/missing-token diagnostics.
It verifies capability-first guidance, no inferred sign-out, explicit expired-session
recovery, multiple missing capabilities, ignored warnings and private-detail exclusion.
The LunaMusic Siri fixture checks that capability and entitlement diagnostics
produce a single Siri message ahead of the signing-session guidance.
Fixtures use synthetic logs and never access credentials, profiles or devices.
A signed build with the correct profile remains separate from these diagnostics tests.

Signing-diagnostic verification (2026-11-02): bootstrap generated the transport
in committed detached source. All 230 Swift tests passed (five optional fixtures
skipped), all 48 Python checks passed, both Go race suites and helper vet passed.
The iOS Simulator client, native arm64 Mac client and separate Mac review package
built with the ignored local identity configuration. The Mac review package
passed strict signature verification. Read-only local/Apple catalog inspection
identified the failing LunaMusic Share extension's missing explicit App ID/profile;
the selected wildcard profile lacks its required App Groups entitlement. The Mac
was locked, so Xcode account UI inspection and automatic provisioning repair could
not be completed. No entitlement was removed, credential changed, physical phone
access/sign-in/install performed, or public notarization/marketplace readiness
established. These checks verify the diagnostic correction, not a repaired signed
LunaMusic build.

## Last-known Apps state

`OrbitPageCacheTests` covers persistence, empty catalogs, corrupt records and peer
isolation. `CodeEditorUITests.testAppsShowsCachedListBeforeRefreshingOnPageLoad`
seeds a private fixture snapshot and delays the live response to verify the saved
row appears first and is replaced. Fixtures never contact a Mac or phone.

Cached-page verification (2026-11-02): bootstrap generated native dependencies in
committed detached source. All 231 Swift checks completed with zero failures
(five optional fixtures skipped), all 48 Python checks passed, and both Go race
suites plus helper vet passed. The iOS Simulator client/test runner and complete
Mac review package built with the ignored local identity configuration; the Mac
package passed strict signature verification. Three Simulator UI checks passed:
cached Apps before a delayed live reply, list failure/retry/empty state, and Mac
update/reconnection. The cached Apps screenshot was inspected. No physical phone
access, Apple sign-in, installation/renewal, public notarization or marketplace
acceptance was performed.


## Live build work

`CodeBuildEventsTests` checks real command-section counting, duplicate/container
exclusion, fragmented and bounded reads, reused action IDs and confirmed build
success. `CodeJobProgressTests` verifies that time, missing metadata and clock
skew cannot manufacture completed work. `testActualBuildTaskDetailsAndProgressUpdateTogether`
checks live counts and the current operation without an estimated percentage;
`testBuildWithoutStageMetadataWaitsForRealUpdates` checks the honest waiting state
and confirmed completion on Simulator. Both use inert jobs, never a phone.

Replay a real Simulator build stream with
`ORBIT_TEST_BUILD_EVENTS=/absolute/path/events.jsonl swift test --filter CodeBuildEventsTests.testResultStreamReplay`.
Create the stream file before building and pass both `-resultStreamPath` and
`-resultBundlePath` to `xcodebuild`. Real task counts measure work, not remaining
time. Physical installation, provisioning renewal, background activity delivery,
notarization and marketplace acceptance remain separate checks.

Live-work verification (2026-11-02): bootstrap generated native dependencies in
committed detached source. All 232 Swift checks passed (six optional fixtures
skipped), all 48 Python checks passed, and both Go race suites plus helper vet
passed. A real iOS Simulator build's result stream passed the optional replay
check separately. Both client builds passed with the ignored local identity;
the complete Mac review bundle passed strict signature verification. Four final
Simulator UI checks passed: live task counts/current operation, missing-metadata
waiting, Apps progress/completion and reconnect/failure. Live-count and waiting
screenshots were reviewed. An initial UI assertion raced two successive polling
snapshots; checking each snapshot's semantics fixed it. No physical phone access,
Apple sign-in, installation/renewal, physical system activity delivery, public
notarization or marketplace acceptance was performed.

## Optional setup in More (2026-11-03)

The iPhone banner is replaced by separate Phone-only refresh and Remote builds
rows in More. Simulator checks passed for all four completion combinations,
independent row badges, the rendered More badge, navigation/back, relaunch and
both cold-launch and delivered expiry notifications. Captures were reviewed in
light and dark appearance. The Refresh screen supplements its existing setup
control with the navigation back button.

Bootstrap generated source-built native dependencies in committed detached
source. All 233 Swift checks completed with zero failures (six optional fixtures
skipped), all 48 Python checks passed, and both Go race suites plus Apple-helper
vet passed. The iOS Simulator client/test runner and complete Mac review bundle
built with the ignored local identity configuration. Strict Mac signature and
packaged phone-source extraction/resume checks passed. Final UI checks used a
separate Simulator after another test run interrupted the shared device.
No physical phone access, Apple sign-in, actual installation/renewal, public
notarization or marketplace acceptance was performed.

## Apps tile grid

`testTargetListDisplaysIconsAndMissingImageFallbacks` checks equal-width columns,
viewport containment, fixed 160 × 220-point cards, 60-point icons, 14hr/2d ages and
history to the left of Play. `testTargetTilesKeepControlsWithLargestText` checks
footer containment at the largest accessibility text size.
`testFixedTargetCardExpandsWithBoundedLongErrorAndSettings` opens the red issue
button, checks fixed card geometry, inset expansion, unchanged icon size,
bounded long-error scrolling, visible controls, schedule updates, reopening and
removal cancellation. The failure/reconnect check opens the issue and logs after
completion. `testBuildRequestFailureUsesIssueIconWithoutResizing` checks rejected
requests retain their message behind the issue icon. The landscape/iPad rotation checks cover fixed card dimensions and expanded
card containment in wide windows.
Other Apps fixtures cover build progress/completion, Wi-Fi rejection, cached
replacement, empty/retry messaging and separate Mac updates. These are inert Mac
replies; they never install on or access a physical phone.

Tile-grid verification (2026-11-03): bootstrap generated native dependencies in
committed detached source. After integrating the latest main, all 233 Swift
checks completed without failures (six optional fixtures skipped), all 48 Python
checks passed, and both Go race suites plus helper vet passed. Both clients built
with the ignored local identity; the complete Mac review bundle passed strict
signature verification. Apps checks passed on iPhone and iPad Simulator for
layout, ages, actions, progress/completion, reconnect/failure, Wi-Fi rejection,
cache replacement, retry/empty state and Mac updates. The integrated revision
also passed small-screen grid/large-text/cache checks and iPad rotation/menu
checks. Screenshots were reviewed in light/dark appearance and at the largest
accessibility text size. Visual review caught an initial offscreen second column;
viewport assertions now cover it. An interrupted shared-Simulator run was rerun.
No physical phone access, Apple sign-in, installation/renewal, public notarization
or marketplace acceptance was performed.


## Build activity lifecycle

`OrbitMonitorTests/CodeBuildMonitorTests` drives the production monitor with an
injected scheduler on Simulator. It checks slow/interrupted startup, one activity
after acceptance, expiration and submission rejection across polls/foreground/
relaunch, late successful launch, stale expiration after a new build, peer
isolation, real build failure and completion before self-install acknowledgement.
The fixture never connects to a Mac or phone. Run with:

```sh
xcodebuild test -project Orbit.xcodeproj -scheme OrbitMonitor \
  -destination 'platform=iOS Simulator,id=YOUR_BOOTED_SIMULATOR' \
  -only-testing:OrbitMonitorTests
```

Physical acceptance separately checks a long Orbit self-build, leaving/reopening
the app and the system activity, iOS expiration/dismissal, and the final native
installation/readback. iOS still controls background lifetime; synthetic scheduler
checks do not establish actual system activity delivery or physical installation.

Build-activity verification (2026-11-03): bootstrap generated native dependencies
in committed detached source. All 243 Swift checks completed without failures
(six optional fixtures skipped); all 48 Python checks, both Go race suites and
Apple-helper vet passed. The iOS Simulator client and complete Mac review bundle
built with the ignored local identity; strict Mac signature verification and
packaged phone-source extraction/resume passed. All nine monitor lifecycle tests
passed, including through the dedicated `OrbitMonitor` scheme. Existing Apps
progress/completion, reconnect/failure and self-update handoff/relaunch UI tests
passed on Simulator. No physical phone access, Apple sign-in, actual system
activity delivery, installation/renewal, public notarization or marketplace
acceptance was performed.


## Phone Code RPC bridge

`CodeClientRPCTests` sends a self-update acknowledgement through the production
JSON adapter and real authenticated Host `code` handler to a synthetic retained
job. It checks persisted acknowledgement, idempotent replies, wrong-token
rejection, structured editor payloads and service/transport errors.
`CodeBuildMonitorTests.testHandoffTimeoutExplainsRecoveryWhileRetainingTheMacJob`
checks the recovery message on a paused retained job. No fixture contacts Apple
or a phone. Physical self-update deployment and subsequent phone-initiated
build/install acceptance are separate from these checks.

Phone-RPC verification (2026-11-03): bootstrap generated source-built native
dependencies in committed detached source. All 246 Swift checks completed
without failures (six optional fixtures skipped), including the real Host
acknowledgement test. All 48 Python checks, both Go race suites and helper vet
passed. The iOS Simulator client and all ten monitor checks passed; the complete
Mac review bundle built with the ignored local identity and passed strict
signature verification. The initial test compilation required moving an awaited
Host reply outside a synchronous XCTest autoclosure. These are synthetic checks;
physical deployment and phone-initiated self-update acceptance remain separate.

Production recovery deployment (2026-11-03): inspection of the stalled live job
showed successful compilation and no installation attempts, followed by a
self-update acknowledgement timeout. That job was cancelled before installation.
After synthetic validation, a Mac-initiated install-only catalog build of
`6720431` compiled committed detached source with the existing ignored local
identity. Native installation and exact installed-build readback succeeded on
the configured phone. This was an explicit recovery deployment, separate from
unattended tests. Reopening the phone app and completing a subsequent
phone-initiated self-build remain manual acceptance; Apple sign-in, provisioning
renewal, public notarization and marketplace acceptance were not exercised.

`OrbitMacAppIconTests` checks installed Mac icon thumbnails, bundle-ID matching,
legacy catalog backfill, changed icons after restart, wire encoding and missing
artwork. Mac catalog lookups never invoke iOS scheme discovery.


## Fixed Apps cards and expansion (2026-11-03)

The grid keeps absolute 160 × 220-point cards across status changes, large text,
and rotation; wider windows add columns. Shared artwork stays at 60 points in
both grid and expanded card. Long error text scrolls inside the expanded card
while refresh, caching, build, logs and removal controls stay within its bounds.
Request rejection, failure after reconnect, direct console access, schedule
updates, reopening, removal cancellation and VoiceOver modal isolation are covered.

Bootstrap generated source-built dependencies in committed detached source.
After integrating the current main, all 247 Swift checks completed without
failures (six optional fixtures skipped), all 48 Python checks passed, and both
Go race suites plus helper vet passed. Both clients built using the ignored local
identity; the complete Mac review bundle passed strict signature verification
and its packaged phone-source extraction/resume check. Eight focused small-iPhone
UI checks, three iPad checks and two dark-appearance checks passed. Portrait
captures were reviewed in light and dark appearance. An iPad rotation command
failed to change the shared Simulator's orientation; the full iPad set passed on
a fresh Simulator. Landscape containment and fixed dimensions passed; XCTest's
landscape screenshot cropping was unsuitable for visual review. Earlier runs
caught background accessibility duplication, stale selection after dismissal and
clipped refresh labels, all corrected before the final checks. The terminal-job
log check now asserts console content instead of a running-only progress view.
No physical phone access, Apple sign-in, installation/renewal, public notarization
or marketplace acceptance was performed.


## Remote build result and monitoring expiration

The Simulator monitor suite checks the system progress fraction through compilation,
repeated snapshots and installation. It exercises success, failure and cancellation
during the final status check at expiration. A stalled reply must release the
activity within the deadline. If installation is still pending after compilation,
the activity says **App built** and foreground polling can later confirm the result
without starting another activity.
Other cases check explicit completed/failed activity titles, failure taking
precedence over a retained handoff, and ending monitoring on a peer change.
`testAppsBuildShowsLiveProgressConsoleAndCompletion` also checks a centered app
heading, separate action label and no overlap with Done in the actual sheet.
These checks use synthetic jobs and Simulator; actual system activity delivery
and physical installation remain separate acceptance checks.

Remote-result verification (2026-11-04): bootstrap generated native dependencies
from committed detached source. All 247 Swift checks completed without failures
(six optional fixtures skipped), all 48 Python checks passed, and both Go race
suites plus helper vet passed. All 13 Simulator monitor tests passed. The final
iOS client passed progress/title geometry, reconnect/failure and self-update
handoff UI checks in dark appearance; progress/title geometry also passed in
light appearance. Both heading captures were reviewed. The final Mac review
package passed strict signature verification and bundled phone-source
extraction/resume. Both client bundle IDs matched ignored local configuration.
Reading the existing Luna Reader job confirmed its recorded installation success;
no new physical-phone access, Apple sign-in, installation/renewal, actual system
activity delivery, notarization or marketplace acceptance was performed.


## Automatic relay and CoreDevice recovery

The route tests cover the LAN → Iroh → Tailscale order, transport pins, legacy
codes and authenticated route sync. The optional public-relay test uses tiny
fixtures, supplies a relay hint with discovery disabled, and waits for direct
before exchanging application data. The private native test establishes a relay
handshake with IP paths disabled and verifies both peers receive zero STREAM or
DATAGRAM data, even when both senders queue bytes.

```sh
IROH_DIRECT_TEST=1 scripts/iroh/build_iroh_direct.sh "$PWD/Vendor/IrohDirect"
ORBIT_TEST_IROH_RELAY=1 swift test --filter OrbitRPCDeliveryTests.testRelayHintBootstrapsDirectConnectionWithoutEndpointDiscovery
```

On a second network, test with Tailscale enabled and disabled. Confirm that
file transfers stop if their direct Iroh path drops and retry on an available
route. Confirm installation separately with exact Apple revision readback.

The CoreDevice tests replay a usage-assertion error with
`remoteServiceDiscoveryTrustedConnectivityAvailable`, check the waiting and
uncertain states before and after handoff, and resume a failed retained job.
Physical acceptance checks an Apps refresh on a second network and installation
with exact revision readback after Xcode reconnects to the iPhone.

Direct Iroh verification (2026-11-16): the source-built relay-policy fixture
passed in both directions. All 253 Swift checks completed without failures
(seven optional fixtures skipped), and the separate relay-assisted direct and
bundled installer tests passed. All 48 Python checks, both Go race suites and
helper vet passed. The iOS Simulator client and signed Mac review app built.
Live tailnet routing and physical-device installation remain manual checks.

The Orbit connection tests exercise recovery after an initial listener failure and
selection of a detected tailnet IP when Automatic has no explicit fallback.
To check the optional login agent, quit Orbit Mac while logged in and verify the
same installed copy reopens with its TCP listener within about 30 seconds.
