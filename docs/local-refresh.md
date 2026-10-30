# Phone-side refresh

Orbit can renew a cached development build without the Mac. A code change still
needs a new Mac build. Refresh does not bypass Apple account limits, add paid
capabilities, or guarantee background execution.

In the iPhone Refresh tab:

1. Connect to Wi-Fi and install/enable LocalDevVPN.
2. Import this phone’s pairing plist. The Mac wizard can explicitly export its
   existing record for manual AirDrop/import. On Mac, choose Export iPhone Pairing
   File after the phone has trusted that Mac (connect by cable, unlock and tap
   Trust if needed). No iOS Apple sign-in or LocalDevVPN setup is needed for
   export. A missing-helper message means the Mac app needs updating/reinstalling.
   This contains private pairing keys;
   keep it private and delete the exported copy after importing. No pairing key is
   sent through Orbit’s control RPC or agent tools.
3. Sign in to your Apple Account. Orbit uses SideStore’s public anisette helper
   (`https://new.ani.sidestore.io`) automatically; no server address is needed. Apple
   receives your email/password; the helper supplies the sign-in data and does not
   receive those credentials. Enable Remember password to keep it in this phone’s
   Keychain for automatic session renewal. Leave it off to keep only the session.
   If your account has one team it is selected automatically; otherwise choose the
   team used to sign the cached build. The form stays open for progress, Apple
   verification and errors. Advanced allows a custom HTTPS anisette service;
   clearing that field restores the default. Existing saved service choices stay
   in use when signing in again. No automatic server rotation is performed.
   The default uses Mac ADI with matching client settings. Error -80045 on an
   older saved helper can be recovered by clearing Advanced’s server field.
   Anisette data is still required by the signing library; removing the remote
   helper entirely would require a separate on-device implementation and its
   native libraries, which Orbit does not currently ship.
4. Import a signing .p12 or explicitly create a development certificate. Existing
   certificates are never automatically revoked. Account repair, certificate
   limits, and two-factor prompts can require foreground attention.
5. Choose Cache Orbit for the client itself. For another installed app, build it
   from the Apps catalog, then choose Cache for Mac-Free Refresh. The archive is
   downloaded in bounded chunks and verified with SHA-256. IPA import also works.
6. Choose Refresh Now. When replacing Orbit itself, go to the Home Screen when
   prompted and reopen Orbit afterward. Enable automatic refresh per app if wanted.

The cache must match the installed bundle, version, build and team. Every app and
extension profile must preserve identifiers, Keychain access and capabilities.
The unchanged cached source is checked before signing; signed workspaces are
separate. Watch-containing builds are rejected by this initial path.

Apple sessions, optional passwords, certificates, private keys and pairing records
live in non-synchronizing `AfterFirstUnlockThisDeviceOnly` Keychain items. These
signing secrets never enter preferences, agent arguments, Mac RPCs or diagnostics.
Sign Out removes account/signing material and preserves the imported pairing file.

A durable installation journal is written before handoff. A lost reply or killed
self update stays unconfirmed until exact installed version/build and every new
profile UUID/expiration are read back. Signing or compilation alone is not success.
Clear Pending Attempt is explicit recovery available after 15 minutes.

Automatic refresh becomes due 48 hours before expiration, backs off for an hour
after an attempt, and requests background windows at least six hours apart. iOS
controls when those windows run. Other apps are processed before Orbit. Keep the
phone app alive by opening it before expiration; an already expired Orbit app
cannot run itself to recover.

Source builds run `scripts/bootstrap_refresh.py` before resolving packages.
SideSign, minimuxer gateway source and the IDevice binary are pinned; notices and
licenses are in [refresh-third-party-notices.md](refresh-third-party-notices.md)
and `Vendor/DeviceGateway`. Bootstrap folds each Rust archive and localizes its
exception personality to avoid a duplicate global with iroh, without changing
its public FFI. The native dependency supports arm64 iPhone/Simulator; x86_64
Simulator builds are excluded.

Physical account sign-in, LocalDevVPN installation, seven-day renewal, extension
renewal, interrupted self replacement and real background scheduling require
acceptance on the intended phone. Simulator and synthetic tests cannot prove them.
