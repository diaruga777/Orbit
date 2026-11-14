# Pick a pipe

All choices carry authenticated app requests. Signing remains on your Mac. A pipe does not bypass Apple's USB/network pairing, Developer Mode, provisioning or device limits.

## Set up in Orbit Mac

Open **Phone & Remote Setup → Build away from home**. **Enable Remote Connections**
starts the built-in iroh listener immediately, including in Xcode-built apps.
Progress, errors and the number of updated phones appear in the sheet. No restart
or replacement pairing code is needed. Keep Orbit open on the paired phone on the
same Wi-Fi until it receives the update. For Automatic, check **Mac relay connected**
and the updated phone count before testing from another network. An
offline phone receives the update on its next connection; both clients must
include automatic route sync. Updating an older client preserves its saved pairing.

**Connection options** includes Local Wi-Fi, Automatic (iroh), Tailscale and a
private Syncthing relay. Tailscale needs its own clients/account; enter the Mac’s
`tcp://` tailnet address in Orbit. For Syncthing, enter a full `relay://` URL with
its certificate ID from a relay you run or trust. Orbit manages its connection to
the relay; deploying a relay server remains an optional infrastructure task. The
CLI commands below are alternatives for automation, never required app setup.

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

Apply in Connection options; existing paired phones receive the route automatically. The code pins Orbit's TLS certificate in addition to Tailscale's network authentication. Orbit never assumes `100.x` is proof of a particular phone. USB or native Xcode Wi-Fi deployment is still a separate connection; remote installation needs the phone forwarding path described in the architecture guide.

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

Apply the relay in Connection options. Its listener owns the relay registration;
phones initiate relay sessions. The relay cannot approve a new phone. Existing
phones receive the route with its pinned Mac identity automatically; no URL
editing or replacement code is needed.

Traffic stays encrypted end to end with the existing pinned identity.

A third-party relay can observe connection metadata and availability. Configure only an operator you chose; Orbit never picks one from a public pool for you.

## dumbpipe / iroh

```sh
bin/orbit configure --provider dumbpipe
```

Enable Automatic (iroh) in Connection options. Existing phones receive its pinned `dumbpipe://…` route automatically. Orbit includes the native [iroh FFI](https://github.com/n0-computer/iroh-ffi), the stream primitive used by [dumbpipe](https://github.com/n0-computer/dumbpipe). The iPhone does not spawn a CLI or need a Rust toolchain. Selecting this provider enables iroh's N0 discovery and relay preset; local-only mode does not start it.

Orbit syncs the Mac’s current relay URL over the authenticated connection. This
lets a phone reach the same pinned endpoint if the network blocks iroh’s endpoint
lookup. If the saved relay is stale, Orbit can still try discovery. The relay URL
does not alter the endpoint key or transfer installation authorization.

The endpoint ID is pinned in the pairing code. Orbit uses ALPN `orbit/1` and its own bounded RPC/install framing. It is not wire-compatible with the desktop CLI's default dumbpipe handshake/tickets; this is a native dumbpipe-style provider. The upstream CLI supports `--custom-alpn` for custom protocols, but pointing a default CLI tunnel at Orbit's owner-only control socket is unsupported. Do not expose that local socket over an unauthenticated tunnel.

The Mac's iroh secret is stored under `~/.orbit/Identity/iroh.key`; the phone's under its private Application Support directory. Removing those keys changes identity and requires pairing again. iroh's normal route may use public relays; choose local Wi-Fi or your own explicit Syncthing relay if that does not fit your needs.

## Diagnostics

`bin/orbit status` reports the selected provider. If control works but installation waits, check Xcode's device connection and unlock the phone. To use remote forwarding, authorize that exact physical phone while the native Apple connection is available, then keep Orbit active or allow an iOS background execution window. A tunnel is not evidence that Apple exposed the required installation services on that phone.
