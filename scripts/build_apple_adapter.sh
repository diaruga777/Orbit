#!/bin/bash
# Shared helper build for Xcode and the complete Mac app packager.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
XCODE=false
if [[ "${1:-}" == --xcode ]]; then
 XCODE=true
 HELPER="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/orbit-apple-adapter"
 NOTICES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AppleAdapterNotices"
else
 [[ $# == 2 ]] || { echo 'Usage: build_apple_adapter.sh HELPER_PATH NOTICES_DIRECTORY | --xcode' >&2; exit 1; }
 HELPER="$1"
 NOTICES="$2"
fi
command -v go >/dev/null || { echo 'Go is needed to build Orbit’s Mac pairing helper. Install Go, then build Orbit Mac again.' >&2; exit 1; }
mkdir -p "$(dirname "$HELPER")" "$NOTICES"
STAGE="$(mktemp -d /tmp/orbit-apple-helper.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
ARCHITECTURES="$(uname -m)"
if $XCODE; then ARCHITECTURES="$ARCHS"; fi
SLICES=()
for ARCHITECTURE in $ARCHITECTURES; do
 case "$ARCHITECTURE" in
  arm64) GO_ARCH=arm64;;
  x86_64) GO_ARCH=amd64;;
  *) echo "Unsupported Mac helper architecture: $ARCHITECTURE" >&2; exit 1;;
 esac
 CGO_ENABLED=0 GOOS=darwin GOARCH="$GO_ARCH" go -C "$ROOT/tools/apple-adapter" build -trimpath -o "$STAGE/$ARCHITECTURE" ./cmd/orbit-apple-adapter
 SLICES+=("$STAGE/$ARCHITECTURE")
done
[[ ${#SLICES[@]} -gt 0 ]] || { echo 'No Mac helper architecture selected.' >&2; exit 1; }
if [[ ${#SLICES[@]} == 1 ]]; then cp "${SLICES[0]}" "$HELPER"; else /usr/bin/lipo -create "${SLICES[@]}" -output "$HELPER"; fi
chmod 755 "$HELPER"
python3 "$ROOT/tools/apple-adapter/notices/collect.py" "$NOTICES"
if $XCODE && [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
 [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]] || { echo 'Xcode did not provide a signing identity for the Mac pairing helper. Check Signing & Capabilities.' >&2; exit 1; }
 SIGN_OPTIONS=(--timestamp=none)
 if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == YES ]]; then SIGN_OPTIONS+=(--options runtime); fi
 /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "${SIGN_OPTIONS[@]}" "$HELPER"
fi
