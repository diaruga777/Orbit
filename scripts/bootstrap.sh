#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
for tool in xcodebuild swift go python3 xcodegen; do
 command -v "$tool" >/dev/null || { echo "Missing $tool. Follow README.md setup." >&2; exit 1; }
done
if [[ ! -d Vendor/OrbitNet.xcframework ]]; then ./scripts/build_transport.sh; fi
python3 scripts/bootstrap_refresh.py
./scripts/iroh/build_iroh_direct.sh "$ROOT/Vendor/IrohDirect"
xcodegen generate
swift package resolve
if [[ ! -f Config/Local.xcconfig ]]; then
 cp Config/Local.xcconfig.example Config/Local.xcconfig
 echo 'Edit Config/Local.xcconfig with your own bundle prefix and Xcode team.'
fi
python3 - "$ROOT" <<'PYSETUP'
import json, os, sys
from pathlib import Path
root=Path(os.environ.get('ORBIT_HOME',str(Path.home()/'.orbit')))
root.mkdir(parents=True,exist_ok=True); root.chmod(0o700)
path=root/'installation.json'
source=Path(sys.argv[1])
common=__import__('subprocess').check_output(['git','rev-parse','--path-format=absolute','--git-common-dir'],cwd=source,text=True).strip()
path.write_text(json.dumps({'checkout':str(Path(common).parent)})); path.chmod(0o600)
PYSETUP
echo 'Orbit is ready. Follow README.md to build the Mac and phone apps.'
