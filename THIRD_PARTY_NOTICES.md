# Third-party software

Orbit's original code is MIT licensed. Dependencies keep their own licenses:

- [Runestone](https://github.com/simonbs/Runestone), pinned 0.5.2, MIT. Its notice and editor acknowledgements are bundled under `Sources/OrbitUI/Resources`.
- [TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages), pinned 0.1.9, and its grammar/runtime dependencies. Preserve the notices in the upstream packages and the editor acknowledgements.
- [swift-syntax](https://github.com/swiftlang/swift-syntax), pinned 602.0.0, Apache-2.0 with Runtime Library Exception; see the upstream license.
- [xcode-build-server](https://github.com/SolaWing/xcode-build-server), vendored at the revision recorded in `Sources/OrbitMac/Resources/BuildServer/REVISION`; its MIT LICENSE remains alongside the source.
- [iroh FFI](https://github.com/n0-computer/iroh-ffi), pinned 1.1.0, MIT/Apache-2.0. The upstream package provides its native library. Build it from source using upstream instructions if you require a source-only dependency chain.
- [go-ios](https://github.com/danielpaulus/go-ios), pinned in `tools/apple-adapter/go.mod`, MIT; its notice is retained under that tool's `notices/`. The Mac build script collects licenses for compiled helper dependencies and the Go runtime into the application bundle.
- [Go](https://go.dev/LICENSE), BSD-style license, used to compile Orbit's source-built transport and installation helper.

The Go TLS/relay implementation originated in Luna's transport sources, which were extracted with Orbit. Orbit does not embed a Tailscale SDK or distribute Syncthing's server. A user who separately installs either tool obtains it under its own license. The sample relay test downloads a pinned upstream server solely to exercise the protocol.
