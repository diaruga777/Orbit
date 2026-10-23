#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/dist/setup-screenshots}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
STAGE="$(mktemp -d /tmp/orbit-setup-capture.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
# Compile the actual view with inert models. No host, transport, phone discovery,
# account access, setup persistence or install commands are linked into this app.
python3 - "$ROOT" "$STAGE" <<'PY'
from pathlib import Path
import sys
root, stage = map(Path, sys.argv[1:])
view = (root/'Sources/OrbitMacApp/OrbitSetupView.swift').read_text()
(stage/'OrbitSetupView.swift').write_text(view.replace('import OrbitHost\n', ''))
types = (root/'Sources/OrbitHost/OrbitSetup.swift').read_text()
types = types[types.index('public enum OrbitSetupStep:'):types.index('/// All mutation')]
(stage/'SetupTypes.swift').write_text('import Foundation\n' + types)
# Keep Continue enablement identical to the production model.
model = (root/'Sources/OrbitMacApp/OrbitSetupModel.swift').read_text()
gate = model[model.index('    var canContinue: Bool {'):model.index('    func persist()')]
fixtures = (root/'tools/setup-screenshots/Capture.swift').read_text()
(stage/'Capture.swift').write_text(fixtures.replace('    // CONTINUE_GATE', gate))
PY
APP="$STAGE/Orbit Setup Screenshots.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 \
  "$STAGE/SetupTypes.swift" "$STAGE/OrbitSetupView.swift" "$STAGE/Capture.swift" \
  -o "$APP/Contents/MacOS/OrbitSetupScreenshots"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OrbitSetupScreenshots</string>
<key>CFBundleIdentifier</key><string>org.example.orbit.setup-screenshots</string>
<key>CFBundleName</key><string>Orbit Setup Screenshots</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
# This accessory capture tool renders offscreen and exits; it does not need a
# Launch Services foreground session (which can be unavailable on a locked Mac).
"$APP/Contents/MacOS/OrbitSetupScreenshots" "$OUTPUT"
python3 - "$OUTPUT" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1])
files = sorted(output.glob('*.png'))
assert len(files) == 16, f'Expected 16 captures, got {len(files)}'
print(f'Captured {len(files)} wizard screens in {output}')
PY
