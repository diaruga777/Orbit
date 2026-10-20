# Bounded Apple installation adapter (Mac)

This is the transport-aware Apple-service component for Code's retained-artifact
installer. It is wired into the production reverse-stream broker, enrolled-key
readiness/session proofs, phone-owned dynamic endpoints and retained-app IPA
packaging. The staged helper's presence gates capability reporting. Physical
acceptance remains pending. The combined synthetic Apple-service check uses a
real private relay and production Swift broker/proxy; it is not an Apple device
installation.

The adapter uses the Mac's existing Apple pairing record, reads only that selected
UDID from the local Apple daemon, and retains credentials only in the short-lived
Mac process. It never pairs, launches, enables Developer Mode or receives host
keys from a phone. It accepts only a restricted dial callback for:

- Lockdown on port 62078;
- AFC and Installation Proxy on exact ports returned by authenticated StartService
  requests for `com.apple.afc` and `com.apple.mobile.installation_proxy`.

Each service starts a fresh Lockdown session. TLS pins the existing paired device
certificate and still verifies TLS handshake signatures. The actual UDID must
match after authentication. This avoids adopting an upstream generic TLS verifier
that accepts any server certificate. A rejected pairing/identity is a distinct
failure class, not permission to try arbitrary transports or other phones.

The Mac validates signature, profile, target and tree digest before preparing an
immutable IPA. This helper uploads it with upstream AFC, issues Install, and reads
back exact bundle ID / short version / build through a fresh authenticated service.
An existing matching revision reconciles a lost reply before another upload. The
handoff flag becomes true before even a partial Install request; a lost response
remains unknown. An explicit Apple error is marked as a definitive failure.
Replacing the forwarding app is rejected and requires a separate proven path.

Limits: one eight-minute operation; 20-second TLS handshakes; ten-second local
pair-record reads; 45-second broker handshakes; 2 MiB plist messages; 64 KiB AFC
replies with header/sequence checks **before** upstream allocation; 8 GiB input;
1,024 install status messages. Context cancellation closes active sockets. The
phone lease/flow authority imposes its own tighter lifetime/byte/flow limits.

## Local helper IPC

Build without contacting a phone:

```sh
go build -trimpath -o /tmp/orbit-apple-adapter ./cmd/orbit-apple-adapter
```

The command takes one owner-only JSON file (maximum 4 KiB):

```json
{
  "artifact": {
    "deviceID": "selected-physical-udid",
    "bundleID": "example.fixture",
    "version": "1.0",
    "build": "123",
    "package": "/private/job/Product.ipa",
    "forwarderBundleID": "example.code"
  },
  "broker": "/tmp/lc-private-job/b.sock",
  "token": "fresh-job-token-at-least-32-characters"
}
```

The broker directory must be owner-only. Use an atomically created short private
path (Darwin Unix socket paths are short; this adapter limits them to 100 bytes),
not a public TCP listener. Never check a real manifest/token/pairing record into
Git. The command emits one JSON result and exits zero only for confirmed readback.
The companion build script compiles it, collects notices and signs it as nested
code using the supplied Mac signing identity. This workflow has not replaced or
launched the persistent Mac app during overnight implementation.

Every local connection begins with `LCA1`, a four-byte big-endian JSON length,
then `{version:1,token,service,port,fullCloseOnEOF:true}` (JSON keys are strings). The broker returns a
single byte `1` only after authorizing the live job token, bound physical endpoint,
generation and lease; otherwise close/reject. The rest is opaque Apple traffic. The pinned helper uses only full connection
closure and explicitly opts into closing its remote flow on Unix EOF; ordinary
half-close clients omit that field. Darwin's Unix hangup flag cannot distinguish
those lifetimes reliably.
The broker must create **only** the two named dynamic service grants returned by
this pinned helper; this IPC must never become an RPC accepting arbitrary ports.
No host/address field exists. The iOS flow framing remains separate from LCA1.

## Checks and source

```sh
go test -race -count=1 -timeout 30s ./...
go vet ./...
go mod verify
```

Tests run genuine TLS/stream/AFC byte exchanges against a **synthetic local Apple
protocol fixture**. They check upload bytes, install/readback, wrong certificate
and UDID, lost completion reconciliation, self-update rejection, cancellation,
allocation bounds, private Unix IPC, manifest permissions and local pair-record
framing. The fixture's bytes are not a signed IPA; these tests do not demonstrate
an Apple device install, background execution or a Syncthing installation path.
No test invokes the real Mac pairing daemon or a phone.

AFC comes from MIT-licensed [go-ios](https://github.com/danielpaulus/go-ios), pinned
to `ca2c56d2c294ff702cadf4821edd30b069d3a264` (2026-10-09), with its notice in
`notices/go-ios-MIT.txt`. `go.mod`/`go.sum` pin the dependency graph; Go 1.26 is
required. No copied executable or developer-machine pairing record ships. This
module does not use upstream's generic SSL activation or device/service discovery.
`notices/collect.py` gathers licenses for modules actually compiled into the
helper plus the Go runtime; the staging script places them in app Resources.
It fails before touching the existing app if a required source/license is missing.

## Combined private-relay check (no phone)

Build an upstream `strelaysrv` executable as described in the
[status report](../../docs/testing.md), then:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1.0-Beta.app/Contents/Developer \
ORBIT_TEST_RELAY_BINARY=/tmp/strelaysrv \
  tools/apple-adapter/integration/run.sh
```

The runner creates an ephemeral loopback-only relay with public pools, status and
NAT disabled, builds a race-instrumented **test binary**, and runs the Swift
integration check. It removes relay keys, broker tokens, certificates and fixtures
on completion. No production manifest, pairing daemon, real phone or signed app
is used. Without the explicit test environment, the integration cases skip.

Data passes through the checked-in production Go/TLS transport, real upstream
relay, LCDF demultiplexer, fresh phone-key proof for each flow, phone proxy and
Swift private Unix broker into `Adapter.Install`. The only substituted endpoint
is a synthetic Apple server on test-only ephemeral loopback ports. Its payload
is deliberately not a signed IPA. Control polling calls the real hub directly;
this check does not exercise physical enrollment, iOS scheduling or network policy.

Four scenarios require exact readback and unchanged uploaded bytes, lost Install
reply followed by readback without another upload, wrong UDID rejection and wrong
paired certificate rejection. Eight fresh proven streams are required for each
successful install/reconciliation scenario; identity failures open one Lockdown
stream and no AFC/install service. Transient private-relay dials retry only while
the demand is pending, with one active dial per demand, as in the phone runtime.
The normal 45-second demand deadline remains enabled. The check never launches
an app or weakens the production command's certificate/pair-record rules.
