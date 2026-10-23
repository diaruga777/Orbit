# Testing

## Reproducible local checks

Run `scripts/bootstrap.sh` first. It generates `Vendor/OrbitNet.xcframework` from this checkout (Mac arm64/x86_64, iOS arm64, Simulator arm64/x86_64). The XCFramework is ignored by Git. CGo compilation flags distinguish each Apple platform in Go's build cache.

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
team metadata parsing and physical-phone readiness evidence. Python MCP tests run
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
