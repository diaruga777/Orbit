# Pick a pipe

All choices carry authenticated app requests. Signing remains on your Mac. A pipe does not bypass Apple's USB/network pairing, Developer Mode, provisioning or device limits.

## Set up in Orbit Mac

Open **Orbit Mac → Settings** (⌘,) or **Phone & Remote Setup**. Choose a
connection type and click **Apply Connection**. Progress, errors and the number
of updated phones appear below the picker. Keep Orbit open on your paired iPhone
on the same Wi-Fi until it syncs. If switching away from iroh, sync both before
and after applying so the Mac recognizes the phone’s TCP identity. For Automatic,
check the updated phone count before leaving Wi-Fi.
The iPhone’s **More → Mac** shows its saved connection type.

Tailscale uses its own clients and account. For Syncthing, enter a full `relay://`
URL with its certificate ID from a relay you run or trust. The CLI commands below
are also available for automation.

Route changes travel over the existing authenticated connection. Each transport
keeps its own pinned identity; phone aliases retain the original account and
installation authorizations. Forgetting phones revokes all linked transport keys.
Local-only mode closes the Mac’s remote listener and turns off public discovery.
Initial pairing still requires explicit approval and identity comparison.

## Local Wi-Fi only

```sh
bin/orbit configure --provider local
```

Choose Local Wi-Fi and apply. For an unpaired phone, open the pairing window and copy the initial code. Allow TCP 49210 through the Mac firewall for Orbit and permit Local Network access. Both devices must be on the same LAN; guest-network client isolation can prevent access. Orbit does not announce to a public discovery service or register a relay in this mode. No extra account is needed. Changing network addresses may require copying a fresh code; certificate identity stays the same.

## Tailscale

Install the separate [Tailscale clients](https://tailscale.com/download) on Mac and iPhone. Sign in to your own tailnet and ensure its access rules allow iPhone → Mac TCP 49210. Orbit neither embeds Tailscale nor owns the tailnet. Find the Mac's [MagicDNS name](https://tailscale.com/kb/1081/magicdns) or tailnet IP:

```sh
bin/orbit configure --provider tailscale --address tcp://YOUR-MAC.YOUR-TAILNET.ts.net:49210
```

In Settings, select **Tailscale**, paste the Mac’s IP or MagicDNS name, and click
**Apply Connection**. Orbit assumes the listener’s port (49210 by default) when
you omit it. Paired phones receive the route automatically and try it before
local Wi-Fi. The pairing pins Orbit’s TLS certificate. Remote Apple installation
uses the separate phone forwarding path described in the architecture guide.

## Syncthing relay

Orbit implements [Syncthing's relay protocol](https://docs.syncthing.net/specs/relay-v1.html). Installing the Syncthing folder-sync app is **not** enough to turn it into an RPC tunnel. A normal Syncthing synced folder is not used to queue commands or install IPAs.

Run an explicit relay on a machine both devices can reach. Build the pinned upstream server yourself if your package manager does not provide it:

```sh
git clone --depth 1 --branch v1.29.7 https://github.com/syncthing/syncthing.git /tmp/orbit-relay-src
go -C /tmp/orbit-relay-src build -o /tmp/strelaysrv ./cmd/strelaysrv
mkdir -p "$HOME/.orbit-relay"
/tmp/strelaysrv -listen 0.0.0.0:22067 -pools '' -status-srv '' -nat=false -keys "$HOME/.orbit-relay"
```

Use the relay URL including its certificate ID printed by the server. Keep the relay's key directory persistent. Expose TCP 22067 only where intended. `-pools ''` prevents enrollment in a public relay pool; `-status-srv ''` disables its status listener. For access outside your LAN, use a reachable relay host or your own network routing. Orbit does not configure router forwarding.

First pair the phone and Mac directly on your LAN. Then:

```sh
bin/orbit configure --provider syncthing --relay 'relay://RELAY-HOST:22067/?id=RELAY_CERTIFICATE_ID'
```

Apply the relay in Settings. Its listener owns the relay registration;
phones initiate relay sessions. The relay cannot approve a new phone. Existing
phones receive the route with its pinned Mac identity automatically; no URL
editing or replacement code is needed.

Traffic stays encrypted end to end with the existing pinned identity.

A third-party relay can observe connection metadata and availability. Configure only an operator you chose; Orbit never picks one from a public pool for you.

## dumbpipe / iroh

```sh
bin/orbit configure --provider dumbpipe
```

Select Automatic (iroh) and apply it in Settings. Existing phones receive its pinned `dumbpipe://…` route automatically. Orbit includes the native [iroh FFI](https://github.com/n0-computer/iroh-ffi), the stream primitive used by [dumbpipe](https://github.com/n0-computer/dumbpipe). The iPhone does not spawn a CLI or need a Rust toolchain. Selecting this provider enables iroh's N0 discovery and relay preset; local-only mode does not start it.

Automatic tries the authenticated local Wi-Fi route first. Away from home, it
uses Iroh to locate the pinned Mac and try a direct path. The Mac shares its
current Iroh relay address with paired phones. Public Iroh relays carry QUIC
setup and path coordination. All Orbit requests, source, artifacts and Apple
installation traffic require a direct path. A direct path that drops closes
that stream.

For fallback, connect both devices to Tailscale, and choose **Automatic**. Orbit detects the Mac’s tailnet IP. To override it,
enter its IP or MagicDNS name in **Tailscale fallback**. Open Orbit on
the paired iPhone over a working connection so it saves the fallback. Tailscale
chooses its own route, including its DERP relays where necessary.

The endpoint ID is pinned in the pairing code. Orbit uses ALPN `orbit/1` and its own bounded RPC/install framing. It is not wire-compatible with the desktop CLI's default dumbpipe handshake/tickets; this is a native dumbpipe-style provider. The upstream CLI supports `--custom-alpn` for custom protocols, but pointing a default CLI tunnel at Orbit's owner-only control socket is unsupported. Do not expose that local socket over an unauthenticated tunnel.

The Mac's iroh secret is stored under `~/.orbit/Identity/iroh.key`; the phone's under its private Application Support directory. Removing those keys changes identity and requires pairing again.

## Diagnostics

`bin/orbit status` reports the selected provider. If control works but installation waits, check Xcode's device connection and unlock the phone. To use remote forwarding, authorize that exact physical phone while the native Apple connection is available, then keep Orbit active or allow an iOS background execution window. A tunnel is not evidence that Apple exposed the required installation services on that phone.
