#!/bin/bash
# Produces a review DMG or, with Developer ID + notarization, a hostable release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---review}"
[[ "$MODE" == --review || "$MODE" == --release ]] || { echo 'Usage: package_dmg.sh [--review|--release]' >&2; exit 2; }
: "${ORBIT_MAC_SIGNING_IDENTITY:?Set an exact valid signing identity. Release requires Developer ID Application.}"
export ORBIT_DISTRIBUTION_MODE="$MODE"
if [[ "$MODE" == --release ]]; then
 : "${ORBIT_NOTARY_PROFILE:?Set the notarytool Keychain profile name.}"
 [[ "$ORBIT_MAC_SIGNING_IDENTITY" == 'Developer ID Application: '* ]] || { echo 'Release signing requires an exact Developer ID Application certificate name.' >&2; exit 1; }
fi
"$ROOT/scripts/build_and_run.sh" --build-only
APP="$ROOT/dist/Orbit Mac.app"
if [[ "$MODE" == --release ]]; then
 /usr/bin/ditto -c -k --keepParent "$APP" "$ROOT/dist/Orbit-notarize.zip"
 xcrun notarytool submit "$ROOT/dist/Orbit-notarize.zip" --keychain-profile "$ORBIT_NOTARY_PROFILE" --wait
 xcrun stapler staple "$APP"
 xcrun stapler validate "$APP"
 spctl --assess --type execute --verbose=2 "$APP"
fi
STAGE="$(mktemp -d /tmp/orbit-dmg.XXXXXX)"; trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/Orbit Mac.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Start Here.txt" <<'HELP'
Open Orbit Mac to start setup. It installs itself, checks Xcode, walks you through
connecting your iPhone, and builds and installs Orbit using your own Apple Account.
Apple's account, trust, Developer Mode, and permission prompts need your approval.
HELP
OUTPUT="$ROOT/dist/Orbit${MODE/--/-}.dmg"
hdiutil create -volname Orbit -srcfolder "$STAGE" -format UDZO -ov "$OUTPUT"
if [[ "$MODE" == --release ]]; then
 codesign --sign "$ORBIT_MAC_SIGNING_IDENTITY" --timestamp "$OUTPUT"
 xcrun notarytool submit "$OUTPUT" --keychain-profile "$ORBIT_NOTARY_PROFILE" --wait
 xcrun stapler staple "$OUTPUT"
 xcrun stapler validate "$OUTPUT"
fi
python3 - "$OUTPUT" <<'CHECKSUM' > "$OUTPUT.sha256"
import hashlib, sys
from pathlib import Path
path=Path(sys.argv[1]); digest=hashlib.sha256()
with path.open('rb') as file:
 while True:
  block=file.read(1024*1024)
  if not block: break
  digest.update(block)
print(digest.hexdigest()+'  '+path.name)
CHECKSUM
echo "$OUTPUT"
