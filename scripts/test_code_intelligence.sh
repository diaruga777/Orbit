#!/usr/bin/env bash
# Builds a disposable UIKit app with an external package, then exercises the
# real Xcode SourceKit server without saving the virtual edits to disk.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /tmp/OrbitIntelligence.XXXXXX)"
FIXTURE="$(cd "$FIXTURE" && pwd -P)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/Support/Sources/FixtureSupport"
cat > "$FIXTURE/Support/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FixtureSupport", products: [.library(name: "FixtureSupport", targets: ["FixtureSupport"])], targets: [.target(name: "FixtureSupport")])
SWIFT
cat > "$FIXTURE/Support/Sources/FixtureSupport/Store.swift" <<'SWIFT'
public struct FixtureStore {
    public init() {}
    public var recordCount: Int { 42 }
    public func readRecord() -> String { "record" }
}
SWIFT
cat > "$FIXTURE/Main.swift" <<'SWIFT'
import UIKit
import FixtureSupport
@main final class FixtureApp: UIResponder, UIApplicationDelegate {
    let store = FixtureStore()
}
SWIFT
cat > "$FIXTURE/project.yml" <<'YAML'
name: Fixture
packages:
  FixtureSupport:
    path: Support
targets:
  Fixture:
    type: application
    platform: iOS
    deploymentTarget: '26.0'
    sources: [Main.swift]
    settings:
      base:
        SWIFT_VERSION: '5.0'
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: dev.orbit.fixture
        CODE_SIGN_STYLE: Automatic
        TARGETED_DEVICE_FAMILY: '1,2'
    dependencies:
      - package: FixtureSupport
schemes:
  Fixture:
    build:
      targets:
        Fixture: all
YAML
(cd "$FIXTURE" && xcodegen generate)

xcodebuild build -project "$FIXTURE/Fixture.xcodeproj" -scheme Fixture \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$FIXTURE/DerivedData" \
  -resultBundlePath "$FIXTURE/BuildResult.xcresult" > "$FIXTURE/build.log" 2>&1 || { cat "$FIXTURE/build.log"; exit 1; }
ORBIT_CODE_INTELLIGENCE_FIXTURE="$FIXTURE" swift test --package-path "$REPO"
