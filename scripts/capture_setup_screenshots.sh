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
disk_check = 'Bundle.main.bundleURL.path.hasPrefix("/Volumes/")'
(stage/'OrbitSetupView.swift').write_text(view.replace('import OrbitHost\n', '').replace(disk_check, 'ScreenshotEnvironment.fromDiskImage'))
types = (root/'Sources/OrbitHost/OrbitSetup.swift').read_text()
types = types[types.index('public enum OrbitSetupStep:'):types.index('/// All mutation')]
(stage/'SetupTypes.swift').write_text('import Foundation\n' + types)
device = (root/'Sources/OrbitCore/CodeBuildCatalog.swift').read_text().split('public struct CodeBuildApp:', 1)[0]
(stage/'Device.swift').write_text(device)
model = (root/'Sources/OrbitMacApp/OrbitSetupModel.swift').read_text()
gate = model[model.index('    var fromDiskImage: Bool {'):model.index('    func persist()')].replace(disk_check, 'ScreenshotEnvironment.fromDiskImage')
fixtures = (root/'tools/setup-screenshots/Capture.swift').read_text()
(stage/'Capture.swift').write_text(fixtures.replace('    // MODEL_PROPERTIES', gate))
PY
APP="$STAGE/Orbit Setup Screenshots.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 \
  "$STAGE/SetupTypes.swift" "$STAGE/Device.swift" "$STAGE/OrbitSetupView.swift" "$STAGE/Capture.swift" \
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
import html, json, struct, sys
output = Path(sys.argv[1])
manifest = json.loads((output/'manifest.json').read_text())
captures = manifest['captures']
assert len(captures) == 13, f'Expected 13 captures, got {len(captures)}'
assert {c['step'] for c in captures} == {'mac', 'phone'}
sections = []
for capture in captures:
    path = output/capture['file']
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', path
    width, height = struct.unpack('>II', data[16:24])
    assert width in (int(capture['width']), 2 * int(capture['width'])) and width * int(capture['height']) == height * int(capture['width']), path
    label = html.escape(path.stem.replace('-', ' '))
    sections.append(f'<section><h2>{label}</h2><a href="{path.name}"><img src="{path.name}" alt="{label}" loading="lazy"></a></section>')
(output/'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Orbit Mac setup screenshots</title><style>body{font:16px system-ui;max-width:1100px;margin:40px auto;padding:0 24px;background:#eef0f4;color:#202430}h1{font-size:28px}h2{font-size:18px}section{margin:40px 0}img{width:100%;border-radius:8px;box-shadow:0 2px 16px #0002}a{color:inherit}</style><h1>Orbit Mac setup</h1><p>13 captures of the actual native wizard, using fictional data and inert actions. No Apple sign-in or phone installation was performed. Click any image for the full-size PNG.</p>'''+''.join(sections)+'</html>')
print(f'Captured and verified {len(captures)} wizard screens in {output}')
PY
