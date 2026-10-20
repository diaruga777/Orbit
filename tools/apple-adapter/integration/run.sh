#!/bin/bash
# Synthetic Apple endpoint only. No phone, usbmuxd, signing or app launch.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
: "${ORBIT_TEST_RELAY_BINARY:?Set ORBIT_TEST_RELAY_BINARY to an upstream strelaysrv executable}"
scratch=$(mktemp -d /tmp/orbit-apple-relay.XXXXXX)
relay_pid=''
cleanup() {
    if [[ -n "$relay_pid" ]]; then kill "$relay_pid" 2>/dev/null || true; wait "$relay_pid" 2>/dev/null || true; fi
    python3 - "$scratch" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
trap cleanup EXIT
port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    print(s.getsockname()[1])
PY
)
mkdir "$scratch/relay"
"$ORBIT_TEST_RELAY_BINARY" -listen "127.0.0.1:$port" -pools '' -status-srv '' -nat=false -keys "$scratch/relay" > "$scratch/relay.log" 2>&1 &
relay_pid=$!
python3 - "$port" <<'PY'
import socket, sys, time
end = time.monotonic() + 10
while True:
    try:
        with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=.5): break
    except OSError:
        if time.monotonic() >= end: raise
        time.sleep(.05)
PY
go -C "$repo/tools/apple-adapter" test -race -c -o "$scratch/apple.test" .
ORBIT_TEST_PRIVATE_RELAY="relay://127.0.0.1:$port" ORBIT_TEST_APPLE_BINARY="$scratch/apple.test" \
    swift test --package-path "$repo" --filter AppleRelayIntegrationTests
