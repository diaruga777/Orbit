# Mac DMG and setup payload

The Mac app owns a resumable setup wizard. Public progress lives in
`~/.orbit/setup.json` (or absolute `ORBIT_HOME`), and setup never stores an Apple
password or private key there. Existing phone namespaces are preserved.

Setup installs the Mac app into `~/Applications/Orbit Mac.app` when opened from a
mounted DMG. An existing installed copy is opened/replaced explicitly in Finder;
setup does not silently replace a client under a different signing requirement.
The normal development build script separately verifies certificate and designated
requirement before replacing its persistent bundle. Keep the bundle ID, path and
certificate stable across builds.

The wizard checks full Xcode, first-launch completion, iOS SDK 26+, and Python. It
opens Apple’s Command Line Tools installer or the Xcode App Store listing when
needed, runs first-launch setup when requested, and waits for Apple’s license,
account, trust and Developer Mode interactions. Xcode selection/components and
account setup may require action in Xcode. It never installs WebDriverAgent.

The phone project is a bundled ZIP of committed source plus the generated native
transport/device archives. A SHA-256 manifest is inside the signed bundle. Setup
extracts it under private `PhoneSource/<revision>`, creates its own committed Git
snapshot (including those ignored native archives), and registers that project
with the normal detached-checkout build service. Personal bundle/team choices
remain build arguments. First Swift dependency resolution needs network access.
The current packaged Mac executable is for the build host architecture; releases
built on Apple Silicon are arm64, not universal.

Every install has a durable target/job ID. An interrupted wizard resumes the job;
only installation/readback success unlocks the connection step. Pairing requires
explicit phone approval. The final refresh step checks a recent authenticated
phone report for account, certificate, pairing, cached self build and a recently checked LocalDevVPN connection. This checks
configuration, not proof of an entire seven-day renewal cycle. Use the intended
account/phone to perform physical acceptance before releasing.

The explicit pairing-file export uses the selected native phone’s existing Apple
pairing record. It requires the full record, rejects another UDID, creates a new
0600 file in a 0700 directory, and does not print keys. The user AirDrops/imports
it and removes the exported copy. No control/MCP route exports pairing secrets.

## Packaging

Run bootstrap, commit the intended source, then use an exact signing identity:

```sh
ORBIT_MAC_SIGNING_IDENTITY='EXACT VALID APPLE DEVELOPMENT CERTIFICATE OR SHA-1' \
  scripts/package_dmg.sh --review
```

This produces `dist/Orbit-review.dmg` and a SHA-256 file. A review DMG is for local
inspection, not Gatekeeper-approved public distribution. It does not replace the
installed Mac client. The DMG contains the setup app, Applications shortcut and
start instructions. macOS does not allow arbitrary downloaded DMGs to autorun;
users open Orbit Mac inside it to launch the wizard.

For a public download, use a **Developer ID Application** certificate and an
existing `notarytool` Keychain credential profile:

```sh
ORBIT_MAC_SIGNING_IDENTITY='Developer ID Application: EXACT CERTIFICATE NAME' \
ORBIT_NOTARY_PROFILE='YOUR_KEYCHAIN_PROFILE' \
  scripts/package_dmg.sh --release
```

The script signs the app/helper with hardened runtime, notarizes/staples the app,
checks Gatekeeper, then signs/notarizes/staples the final DMG. It stops on failure.
Host `dist/Orbit-release.dmg` only after those checks and physical acceptance.
Signing and notary credentials never enter the repository or DMG.

The Xcode OrbitMac scheme remains useful for development compilation; use the
packaging/build script for the complete setup/source/helper/plugin resources.

The bundled wizard uses Homebrew’s upstream `xcodesorg/made/xcodes` package for
Xcode installation. It exposes the upstream interactive prompts in Orbit, and
retains no installer transcript. Signing login stays in Xcode; download login in
xcodes does not sign the user into Xcode Accounts. Phone-only refresh and remote
setup are post-onboarding options in both clients, with local Wi-Fi as default.
