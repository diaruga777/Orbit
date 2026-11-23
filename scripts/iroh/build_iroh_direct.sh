#!/bin/bash
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?Give the output Swift package path.}"
PATCH="$SCRIPTS/iroh-direct.patch"
REVISION=5e451092dba0c1a09ee83ff6e5be37b1152a5c58
VERSION=1.1.0
STAMP="$(cat "$PATCH" "$SCRIPTS/IrohDirectPackage.swift" "$SCRIPTS/IrohDirectConnection.swift" "$SCRIPTS/stage_iroh_frameworks.py" | shasum -a 256 | cut -d ' ' -f 1) $REVISION"
if [[ "${IROH_DIRECT_TEST:-0}" != 1 && -f "$OUT/Iroh.xcframework/Info.plist" &&
      -f "$OUT/.version" && "$(cat "$OUT/.version")" == "$STAMP" ]]; then
  exit 0
fi
[[ "${2:-}" != --check ]] || exit 1
CARGO="${ORBIT_CARGO:-cargo}"
command -v "$CARGO" >/dev/null || { echo 'Install Rust with rustup to build the Iroh transport.' >&2; exit 1; }
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
curl -fsSL "https://codeload.github.com/n0-computer/iroh-ffi/tar.gz/$REVISION" | tar -xz -C "$SCRATCH"
FFI="$SCRATCH/iroh-ffi-$REVISION"
PROTO="$SCRATCH/noq-proto-1.0.1"
curl -fsSL https://static.crates.io/crates/noq-proto/noq-proto-1.0.1.crate -o "$SCRATCH/noq.crate"
echo "aa6c890013591e709a3e45dd53501351b7e27e7ff3c7e9fc3dce43e300e7e9d3  $SCRATCH/noq.crate" | shasum -a 256 -c -
tar -xf "$SCRATCH/noq.crate" -C "$SCRATCH"
patch -s -d "$PROTO" -p1 < "$PATCH"
printf '\n[patch.crates-io]\nnoq-proto = { path = "../noq-proto-1.0.1" }\n' >> "$FFI/Cargo.toml"
python3 - "$FFI/Cargo.lock" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
original = p.read_text()
registry_entry = ('name = "noq-proto"\nversion = "1.0.1"\n'
                  'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
                  'checksum = "aa6c890013591e709a3e45dd53501351b7e27e7ff3c7e9fc3dce43e300e7e9d3"\n')
assert original.count(registry_entry) == 1
p.write_text(original.replace(registry_entry, registry_entry.split('source =')[0]))
PY
export IPHONEOS_DEPLOYMENT_TARGET=17.5 MACOSX_DEPLOYMENT_TARGET=15.0
export CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_STRIP=debuginfo
BUILD="${IROH_DIRECT_CARGO_TARGET_DIR:-$HOME/Library/Caches/orbit-luna/iroh-direct}"
"$CARGO" build --locked --manifest-path "$FFI/Cargo.toml" --release --lib --target-dir "$BUILD" \
  --target aarch64-apple-darwin --target aarch64-apple-ios --target aarch64-apple-ios-sim --target x86_64-apple-ios
if [[ "${IROH_DIRECT_TEST:-0}" == 1 ]]; then
  mkdir -p "$FFI/tests"
  cp "$SCRIPTS/relay_policy.rs" "$FFI/tests/"
  python3 - "$FFI/Cargo.toml" <<'PYTEST'
from pathlib import Path
import sys
p = Path(sys.argv[1])
manifest = p.read_text()
p.write_text(manifest.replace('[dev-dependencies]', '''[dev-dependencies]
iroh = { version = "=1.0.2", features = ["test-utils"] }
iroh-relay = { version = "=1.0.2", features = ["test-utils"] }'''))
PYTEST
  "$CARGO" test --manifest-path "$FFI/Cargo.toml" --target-dir "$BUILD/verification" --release \
    --target aarch64-apple-darwin --test relay_policy
fi
# The pin supplies the generated Swift and C ABI for the unchanged FFI interface.
# Only the headers are copied from the upstream release. All linked archives
# below are from the patched, locked source build.
curl -fsSL "https://github.com/n0-computer/iroh-ffi/releases/download/v$VERSION/IrohLib.xcframework.zip" -o "$SCRATCH/headers.zip"
echo "ad46dadf09f9224157512992923562931ed60f252414230d50893a4d515c5776  $SCRATCH/headers.zip" | shasum -a 256 -c -
unzip -q "$SCRATCH/headers.zip" 'Iroh.xcframework/macos-arm64/Headers/*' -d "$SCRATCH"
HEADERS="$SCRATCH/Iroh.xcframework/macos-arm64/Headers"
PACKAGE="$SCRATCH/package"
mkdir -p "$PACKAGE/Sources/IrohLib"
cp "$FFI/IrohLib/Sources/IrohLib/IrohLib.swift" "$PACKAGE/Sources/IrohLib/"
cp "$FFI/LICENSE-APACHE" "$FFI/LICENSE-MIT" "$PACKAGE/"
cp "$SCRIPTS/IrohDirectPackage.swift" "$PACKAGE/Package.swift"
cp "$SCRIPTS/IrohDirectConnection.swift" "$PACKAGE/Sources/IrohLib/"
python3 "$SCRIPTS/stage_iroh_frameworks.py" "$BUILD" "$HEADERS" "$SCRATCH/frameworks" "$PACKAGE/Iroh.xcframework"
printf '%s\n' "$STAMP" > "$PACKAGE/.version"
mkdir -p "$(dirname "$OUT")"
rm -rf "$OUT"
mv "$PACKAGE" "$OUT"
