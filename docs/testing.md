# Testing

## Reproducible local checks

Run `scripts/bootstrap.sh` first. It generates `Vendor/OrbitNet.xcframework` from this checkout (Mac arm64/x86_64, iOS arm64, Simulator arm64/x86_64). The XCFramework is ignored by Git. CGo compilation flags distinguish each Apple platform in Go's build cache.

The macOS `COrbitNet.framework` slice uses the versioned macOS framework layout:
its binary, headers, modules and `Resources/Info.plist` live under `Versions/A`,
with the standard `Versions/Current` and top-level framework symlinks. iOS and
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

For app-icon changes, regenerate the project with XcodeGen and verify the iOS
build contains `Assets.car` and declares `CFBundleIcons` / `AppIcon`. Also build
the `OrbitMac` Xcode scheme and check its icon metadata. The script-built Mac
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

`OrbitHostTests.testTargetIconsBackfillOlderCatalogAndSurviveRestart` covers legacy target icon migration, wire encoding, persistence and throttled lookup failures. `CodeEditorUITests.testTargetListDisplaysIconsAndMissingImageFallbacks` exercises the actual Apps controller with a thumbnail, absent image and invalid image; its screenshot attachment supports visual review without pairing a phone.

Build-catalog tests cover legacy install-only defaults and per-scheme launch
preferences surviving discovery and cache reload. The Simulator build fixture
rejects Play requests with an unexpected `installOnly` value.
`CodeEditorUITests.testLaunchAfterInstallIsPerSchemeAndPersistsAcrossDiscoveryAndRelaunch`
checks launch opt-in, persistence and independence between schemes sharing a
bundle ID. The existing background/startup tests exercise default install-only
requests after leaving Orbit. These fixtures never install on a physical phone.

## SourceKit with a real disposable Xcode app

`scripts/test_code_intelligence.sh` generates a UIKit fixture with a local package, builds it for Simulator and checks real SourceKit completion/diagnostics with unsaved edits. It leaves the fixture source unchanged and never launches an app or contacts a phone.

## Private relay and synthetic Apple endpoint

```sh
git clone --depth 1 --branch v1.29.7 https://github.com/syncthing/syncthing.git /tmp/orbit-relay-source
go -C /tmp/orbit-relay-source build -o /tmp/orbit-strelaysrv ./cmd/strelaysrv
ORBIT_TEST_RELAY_BINARY=/tmp/orbit-strelaysrv tools/apple-adapter/integration/run.sh
```

The runner starts a private loopback relay with public pools, NAT traversal and status disabled, then connects the production TLS/stream broker and pinned helper to a synthetic Apple service. It checks successful readback, lost replies, wrong UDID and wrong certificate. It never reads real pairing records or installs an app on a phone.

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
`OrbitSetupBannerUITests` checks both optional setup destinations and persistent
dismissal in Simulator. The banners do not initiate remote configuration or Apple
sign-in merely by appearing.

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

Interactive acceptance: in an Xcode-built Mac app, open Phone & Remote Setup,
enable remote connections and check immediate status/progress. Verify automatic
route sync on an already paired updated iOS client, offline-phone catch-up, both
clients restarting, local Wi-Fi fallback, switching back to local-only, and
Tailscale/private-relay errors. Existing Apple installation authorization must
survive transport changes. Internet reachability and physical installations need
separate physical acceptance; unit tests do not establish them. The synthetic
reverse-flow byte/half-close/replay check also covers iroh readiness. Active phone
forwarding restarts when route snapshots change and resolves the current pinned
route for each Apple stream.

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
