#!/bin/bash
# One committed-source build/install path for Xcode, agents and both Orbit clients.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
exec python3 "$ROOT/scripts/mac_build.py" "$@"
