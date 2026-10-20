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

## SourceKit with a real disposable Xcode app

`scripts/test_code_intelligence.sh` generates a UIKit fixture with a local package, builds it for Simulator and checks real SourceKit completion/diagnostics with unsaved edits. It leaves the fixture source unchanged and never launches an app or contacts a phone.

## Private relay and synthetic Apple endpoint

```sh
git clone --depth 1 --branch v1.29.7 https://github.com/syncthing/syncthing.git /tmp/orbit-relay-source
go -C /tmp/orbit-relay-source build -o /tmp/orbit-strelaysrv ./cmd/strelaysrv
ORBIT_TEST_RELAY_BINARY=/tmp/orbit-strelaysrv tools/apple-adapter/integration/run.sh
```

The runner starts a private loopback relay with public pools, NAT traversal and status disabled, then connects the production TLS/stream broker and pinned helper to a synthetic Apple service. It checks successful readback, lost replies, wrong UDID and wrong certificate. It never reads real pairing records or installs an app on a phone.

## Physical acceptance

Before treating a release as verified for unattended personal use, test using the intended Xcode/account/phone:

- First installation with a free Personal Team, then profile renewal before seven-day expiry; verify the installed profile's new expiration and extensions.
- Scheduled install while the Mac is awake and iPhone is available; confirm the exact installed bundle/version/build.
- Mac/app restart, queued job recovery, missing phone, a locked phone, network change and signing failure.
- Local Wi-Fi and chosen remote pipe; explicit phone authorization, foreground and iOS-controlled background readiness, peer revocation and refusal to self-replace the active forwarder.
- Updating Orbit through an independent native Apple connection; preserving drafts and app identity.

No WebDriverAgent is allowed on a physical phone. Simulator compilation, synthetic Apple protocols and GitHub CI do not substitute for this acceptance. Marketplace acceptance and Apple account setup are separate manual workflows.

## Extraction verification (2026-10-21)

Local verification used Xcode 26.2, Go 1.26.4 and an iOS 26.2 Simulator:

- 108 Swift tests passed. The real SourceKit fixture enabled both otherwise-skipped intelligence checks; only the separate private-relay fixture was skipped in that run.
- The private-relay/Apple-protocol fixture passed separately using the production transport, scoped stream broker and helper.
- Five Python MCP tests and both Go race-test suites passed.
- The iOS client and UI-test runner built; project selection/restoration and save-conflict recovery both passed on Simulator.
- The complete Mac app bundle built and passed signature verification. Its running local service answered CLI status, target listing, GitHub search and Xcode-project inspection.
- Plugin manifest/MCP JSON validated against the published Agent Plugins schemas; both bundled skills passed validation and the plugin launcher completed MCP initialization.
- Luna Mac's remaining 13 tests and Luna Vault's Simulator build passed after removal of Code services.

Mac window visual inspection was unavailable while the screen was locked. No physical phone, Personal Team renewal cycle, unattended background installation or public marketplace acceptance is claimed by these checks.
