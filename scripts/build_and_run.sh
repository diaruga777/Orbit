#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
cd "$ROOT"
[[ -d Vendor/OrbitNet.xcframework ]] || ./scripts/build_transport.sh
# Read the checked-in default and ignored override without executing either file.
PREFIX="$(python3 - <<'PY'
from pathlib import Path
value='org.example.orbit'
for name in ['Config/Orbit.xcconfig','Config/Local.xcconfig']:
 if Path(name).exists():
  for line in Path(name).read_text().splitlines():
   if line.startswith('ORBIT_BUNDLE_PREFIX = '): value=line.split('=',1)[1].split('//',1)[0].strip()
if not value or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-' for c in value): raise SystemExit('Invalid ORBIT_BUNDLE_PREFIX')
print(value)
PY
)"
IDENTITY="${ORBIT_MAC_SIGNING_IDENTITY:-}"
BUNDLE="${ORBIT_MAC_APP_PATH:-$HOME/Applications/Orbit Mac.app}"
if [[ -z "$IDENTITY" && "$MODE" != --build-only ]]; then
 echo 'Set ORBIT_MAC_SIGNING_IDENTITY to the exact Apple Development certificate name or SHA-1 from security find-identity -v -p codesigning.' >&2
 exit 1
fi
if [[ -n "$IDENTITY" ]]; then
 MATCHES="$(security find-identity -v -p codesigning | awk -F '"' -v requested="$IDENTITY" '{ split($1,a," "); if (a[2] == requested || $2 == requested) print a[2] }')"
 [[ -n "$MATCHES" && "$MATCHES" != *$'\n'* ]] || { echo 'No unique valid signing certificate matched.' >&2; exit 1; }
 IDENTITY="$MATCHES"
fi
# Build-only output is a separate review artifact; it never overwrites an installed client.
if [[ "$MODE" == --build-only ]]; then BUNDLE="$ROOT/dist/Orbit Mac.app"; fi
swift build --product OrbitMacApp
BUILD="$(swift build --show-bin-path)"
go -C tools/apple-adapter build -trimpath -o "$BUILD/orbit-apple-adapter" ./cmd/orbit-apple-adapter
python3 tools/apple-adapter/notices/collect.py "$BUILD/apple-adapter-notices"
STAGE="$(mktemp -d /tmp/orbit-app.XXXXXX)"; trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Orbit Mac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/AppleAdapterNotices"
cp "$BUILD/OrbitMacApp" "$APP/Contents/MacOS/OrbitMacApp"
cp "$BUILD/orbit-apple-adapter" "$APP/Contents/Helpers/"
cp -R "$BUILD/apple-adapter-notices/." "$APP/Contents/Resources/AppleAdapterNotices/"
for resource in "$BUILD"/*.bundle; do [[ ! -d "$resource" ]] || cp -R "$resource" "$APP/Contents/Resources/"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OrbitMacApp</string>
<key>CFBundleIdentifier</key><string>$PREFIX.mac</string>
<key>OrbitPhoneBundleIdentifier</key><string>$PREFIX.ios</string>
<key>CFBundleName</key><string>Orbit Mac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>Orbit connects to your phone to build and install your apps.</string>
</dict></plist>
PLIST
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP/Contents/Helpers/orbit-apple-adapter"
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
codesign -dv --verbose=2 "$APP"
if [[ "$MODE" != --build-only && -d "$BUNDLE" ]]; then
 EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$BUNDLE/Contents/Info.plist")"
 [[ "$EXISTING_ID" == "$PREFIX.mac" ]] || { echo 'Existing app has a different bundle ID. Keep its configuration and location stable.' >&2; exit 1; }
 # A change of certificate must be intentional; preserving the designated
 # requirement keeps macOS file grants tied to the same installed client.
 REQ="$(codesign -d -r- "$BUNDLE" 2>&1 | sed -n 's/^designated => //p')"
 if [[ -n "$REQ" ]]; then codesign --verify --test-requirement "$REQ" "$APP"; fi
 pkill -x OrbitMacApp >/dev/null 2>&1 || true
fi
mkdir -p "$(dirname "$BUNDLE")"
# ditto updates the same bundle path after the new app has passed verification.
/usr/bin/ditto "$APP" "$BUNDLE"
case "$MODE" in
 --build-only) echo "$BUNDLE";;
 run) open -n "$BUNDLE";;
 --verify) open -n "$BUNDLE"; sleep 2; pgrep -x OrbitMacApp >/dev/null;;
 --debug) lldb -- "$BUNDLE/Contents/MacOS/OrbitMacApp";;
 --logs|--telemetry) open -n "$BUNDLE"; /usr/bin/log stream --info --predicate 'process == "OrbitMacApp"';;
 *) echo 'Usage: scripts/build_and_run.sh [run|--build-only|--verify|--debug|--logs|--telemetry]' >&2; exit 2;;
esac
