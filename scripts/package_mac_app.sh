#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=--build-only
[[ "$(git rev-parse --abbrev-ref HEAD)" == HEAD && -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Package only committed source in a detached worktree." >&2; exit 1; }
cd "$ROOT"
[[ -d Vendor/OrbitNet.xcframework ]] || ./scripts/build_transport.sh
# Both app paths use the user's ignored identity; never build sample identifiers.
PREFIX="$(python3 scripts/local_identity.py --field prefix)"
PHONE_ID="$(python3 scripts/local_identity.py --field phone)"
IDENTITY="${ORBIT_MAC_SIGNING_IDENTITY:-}"
BUNDLE="$ROOT/dist/Orbit Mac.app"
# Build-only output is a separate review artifact; it never overwrites an installed client.
if [[ "$MODE" == --build-only ]]; then BUNDLE="$ROOT/dist/Orbit Mac.app"; fi
swift build --scratch-path "${ORBIT_MAC_BUILD_CACHE:-$ROOT/.build}" --build-system native --product OrbitMacApp -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=${ORBIT_SOURCE_ROOT:-$ROOT}"
BUILD="$(swift build --scratch-path "${ORBIT_MAC_BUILD_CACHE:-$ROOT/.build}" --build-system native --show-bin-path)"
"$ROOT/scripts/build_apple_adapter.sh" "$BUILD/orbit-apple-adapter" "$BUILD/apple-adapter-notices"
STAGE="$(mktemp -d /tmp/orbit-app.XXXXXX)"; trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Orbit Mac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/AppleAdapterNotices"
# Use the same Dock artwork as the Xcode app target.
mkdir -p "$STAGE/Orbit.iconset"
cp "$ROOT/Apps/OrbitMac/Assets.xcassets/AppIcon.appiconset/"*.png "$STAGE/Orbit.iconset/"
iconutil --convert icns "$STAGE/Orbit.iconset" --output "$APP/Contents/Resources/Orbit.icns"
cp "$BUILD/OrbitMacApp" "$APP/Contents/MacOS/OrbitMacApp"
cp "$BUILD/orbit-apple-adapter" "$APP/Contents/Helpers/"
cp -R "$BUILD/apple-adapter-notices/." "$APP/Contents/Resources/AppleAdapterNotices/"
# Bundle everything setup needs except Apple-owned Xcode/account prerequisites.
python3 "$ROOT/scripts/package_phone_source.py" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/AgentTools/bin" "$APP/Contents/Resources/AgentTools/plugins"
cp "$ROOT/bin/orbit" "$APP/Contents/Resources/AgentTools/bin/orbit"
python3 "$ROOT/scripts/package_plugin.py" codex "$APP/Contents/Resources/AgentTools/plugins/orbit"
mkdir -p "$APP/Contents/Resources/AgentTools/scripts"
cp "$ROOT/scripts/"{mac_build.py,local_identity.py} "$APP/Contents/Resources/AgentTools/scripts/"
for resource in "$BUILD"/*.bundle; do [[ ! -d "$resource" ]] || cp -R "$resource" "$APP/Contents/Resources/"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OrbitMacApp</string>
<key>CFBundleIdentifier</key><string>$PREFIX.mac</string>
<key>OrbitPhoneBundleIdentifier</key><string>$PHONE_ID</string>
<key>OrbitRevision</key><string>$(git rev-parse HEAD)</string>
<key>CFBundleName</key><string>Orbit Mac</string>
<key>CFBundleIconFile</key><string>Orbit.icns</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>Orbit connects to your phone to build and install your apps.</string>
</dict></plist>
PLIST
python3 - "$APP/Contents/Info.plist" <<'METADATA'
import os, plistlib, sys
from pathlib import Path
p=Path(sys.argv[1]); data=plistlib.loads(p.read_bytes())
if os.environ.get('ORBIT_CANONICAL_BUILD') == '1':
 data.update(OrbitSourceRoot=os.environ['ORBIT_SOURCE_ROOT'], OrbitStateRoot=os.environ['ORBIT_STATE_ROOT'], OrbitCanonicalPath=str(Path.home()/'Applications/Orbit Mac.app'))
p.write_bytes(plistlib.dumps(data))
METADATA
if [[ "${ORBIT_DISTRIBUTION_MODE:---review}" == --release ]]; then
 codesign --force --options runtime --sign "$IDENTITY" --timestamp "$APP/Contents/Helpers/orbit-apple-adapter"
else
 codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP/Contents/Helpers/orbit-apple-adapter"
fi
if [[ "${ORBIT_DISTRIBUTION_MODE:---review}" == --release ]]; then
 codesign --force --options runtime --sign "$IDENTITY" --timestamp "$APP"
else
 /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$STAGE/debug-entitlements.plist"
 codesign --force --sign "${IDENTITY:--}" --entitlements "$STAGE/debug-entitlements.plist" --timestamp=none "$APP"
fi
codesign --verify --deep --strict "$APP"
codesign -dv --verbose=2 "$APP"
mkdir -p "$(dirname "$BUNDLE")"
/usr/bin/ditto "$APP" "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
echo "$BUNDLE"
