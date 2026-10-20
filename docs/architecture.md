# Architecture

Orbit is independent of Luna. It contains a source editor, a Mac executor and transport adapters; it does not link Luna's Vault, Music, premium, app configuration or saves database.

| Component | Responsibility |
| --- | --- |
| `OrbitCore` | Codable requests, revisions, drafts, job state, retained artifacts, phone-bound install grants |
| `OrbitMac` | File editing, SourceKit, Xcode build jobs, isolated Git worktrees, signing/profile checks, native and bounded remote installation |
| `OrbitUI` | UIKit editor, syntax highlighting, completion, diagnostics and build views extracted from Luna Code |
| `OrbitWire` | Peer IDs, bounded byte streams and pairing routes |
| `OrbitTransport` | Source-built Go mutual TLS, explicit Syncthing relays, native iroh streams, framing and phone-owned service forwarding |
| `OrbitHost` | App catalog, GitHub browsing/inspection/import, persistent schedules, local control socket and authenticated remote server |
| `OrbitMacApp` / `Apps/Orbit` | Standalone Mac and iOS composition and setup |
| `bin/orbit` | Python CLI and stdio MCP using the same running Mac service |

Data lives under `~/.orbit` on Mac (override with absolute `ORBIT_HOME`) and private Application Support on iOS. Pairing certificates and iroh keys are independent of signing certificates. The phone's installation authorization key is non-synchronizing and stays in Keychain. Removing an app or its state requires pairing again; no Luna identity is silently adopted.

## Requests and jobs

The local CLI uses a Unix socket inside the owner-only state directory. Remote peers use mutually authenticated TLS or pinned iroh endpoint keys and must be explicitly trusted by the Mac. Control frames begin with `ORBT`, followed by a four-byte big-endian JSON length; the 12 MiB cap is checked before payload allocation. Each RPC uses a fresh bounded exchange. Installation streams use their separate LCDF protocol and phone-key proof.

The Mac checks its schedule every minute. Success means a confirmed installation, not just compilation. Submission IDs and pending requests are persisted before dispatch; jobs, logs, artifacts and install evidence survive restart. Builds use a detached checkout of the configured committed branch. GitHub-managed targets fetch their configured branch; local targets never pull or rewrite the user's checkout.

Profile refresh is scoped to the selected automatic-signing team, bundle identifier and phone. Only cache entries expiring before the requested lifetime are moved aside, with a recovery journal. Xcode does the actual provisioning. The built app and extensions are checked before deployment. Credentials remain in Apple's existing tools.

## Remote installation

A control pipe by itself does not expose Apple's installation services. Native deployment uses the Mac's existing Xcode/CoreDevice USB or Wi-Fi connection. The optional remote path:

1. Enrolls the physical phone while that native Apple connection can verify its private installation key through its own Orbit app container.
2. Lets the phone advertise short-lived readiness while Orbit runs.
3. Opens a fresh phone-initiated, authenticated stream for each bounded Apple service demand.
4. Restricts forwarding to Lockdown and authenticated dynamic AFC/Installation Proxy ports on that phone's own interfaces.
5. Uses the Mac's existing selected pairing record through the bundled helper, pins the paired device certificate, validates UDID, installs the retained signed artifact, and reads back exact bundle/version/build.

No arbitrary host/port proxy, host-key export, new device pairing, Developer Mode enablement or UI automation is offered by this path. Self-replacement of the app carrying the forwarding session is rejected. Updating Orbit itself requires the independent native Apple path.

The iOS client offers readiness in the foreground and requests BGProcessing windows for later attempts. iOS decides whether and when a background window runs; expiry, lock state, Wi-Fi policy and Apple's device services can prevent installation. Artifacts remain waiting, and uncertain completion is reconciled before retry. The inherited implementation has synthetic Apple/TLS/relay coverage; **the standalone Orbit extraction has not been accepted on a physical phone or a free Personal Team in CI**. Do not infer those results from simulator builds.

## Known boundaries

- An Xcode project-file check is preliminary. Private dependencies, missing secrets, unsupported entitlements, nonshared schemes or an unavailable SDK can still stop a build.
- Apple's Personal Team restrictions remain in force. Automated refresh cannot create more app slots or add paid capabilities.
- The native dumbpipe-style adapter uses iroh with Orbit's ALPN, not the stock desktop CLI's default protocol.
- The Mac must be logged in, awake, with Xcode account access available. No always-on Luna/Orbit hosted service fills that role.
- There is no automatic signing-key migration or public binary distribution/notarization in this initial source release. Each user builds and signs the clients for their own setup.
