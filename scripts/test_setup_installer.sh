#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d /tmp/orbit-installer-probe.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
  "$ROOT/Sources/OrbitMacApp/OrbitToolInstaller.swift" \
  "$ROOT/tools/setup-installer-tests/Probe.swift" -o "$STAGE/installer-probe"
"$STAGE/installer-probe"
