#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/orbit-net.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
command -v go >/dev/null || { echo 'Install Go: brew install go' >&2; exit 1; }
mkdir -p "$ROOT/Vendor"
cat > "$WORK/clang" <<'CC'
#!/bin/sh
exec xcrun --sdk "$ORBIT_SDK" clang -isysroot "$(xcrun --sdk "$ORBIT_SDK" --show-sdk-path)" -arch "$ORBIT_CLANG_ARCH" "$ORBIT_MIN_FLAG" "$@"
CC
chmod +x "$WORK/clang"
cd "$ROOT/Transport/Go"
for slice in macos-arm64 macos-amd64 ios-arm64 sim-arm64 sim-amd64; do
 case "$slice" in
 macos-arm64) sdk=macosx; target=arm64-apple-macos15; os=darwin; arch=arm64;;
 macos-amd64) sdk=macosx; target=x86_64-apple-macos15; os=darwin; arch=amd64;;
 ios-arm64) sdk=iphoneos; target=arm64-apple-ios26.0; os=ios; arch=arm64;;
 sim-arm64) sdk=iphonesimulator; target=arm64-apple-ios26.0-simulator; os=ios; arch=arm64;;
 sim-amd64) sdk=iphonesimulator; target=x86_64-apple-ios26.0-simulator; os=ios; arch=amd64;;
 esac
 case "$slice" in
 macos-*) minflag=-mmacosx-version-min=15.0;;
 ios-*) minflag=-miphoneos-version-min=26.0;;
 sim-*) minflag=-mios-simulator-version-min=26.0;;
 esac
 clangarch="$arch"; [ "$arch" != amd64 ] || clangarch=x86_64
 echo "Building Orbit transport: $slice"
 CGO_CFLAGS="-target $target" CGO_LDFLAGS="-target $target" CGO_ENABLED=1 GOOS="$os" GOARCH="$arch" ORBIT_SDK="$sdk" ORBIT_TARGET="$target" ORBIT_CLANG_ARCH="$clangarch" ORBIT_MIN_FLAG="$minflag" CC="$WORK/clang" \
  go build -trimpath -ldflags=-w -buildmode=c-archive -o "$WORK/$slice.a" .
done
lipo -create "$WORK/macos-arm64.a" "$WORK/macos-amd64.a" -output "$WORK/macos.a"
lipo -create "$WORK/sim-arm64.a" "$WORK/sim-amd64.a" -output "$WORK/sim.a"
for platform in macos ios sim; do
 framework="$WORK/products/$platform/COrbitNet.framework"
 mkdir -p "$framework/Headers" "$framework/Modules"
 case "$platform" in
 macos) archive="$WORK/macos.a";;
 ios) archive="$WORK/ios-arm64.a";;
 sim) archive="$WORK/sim.a";;
 esac
 cp "$archive" "$framework/COrbitNet"
 cp orbitnet.h "$framework/Headers/"
 cat > "$framework/Modules/module.modulemap" <<'MAP'
framework module COrbitNet { umbrella header "orbitnet.h" export * }
MAP
 cat > "$framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.orbit.transport</string><key>CFBundleExecutable</key><string>COrbitNet</string><key>CFBundleName</key><string>COrbitNet</string><key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleVersion</key><string>1</string></dict></plist>
PLIST
done
rm -rf "$ROOT/Vendor/OrbitNet.xcframework"
xcodebuild -create-xcframework -framework "$WORK/products/macos/COrbitNet.framework" \
 -framework "$WORK/products/ios/COrbitNet.framework" -framework "$WORK/products/sim/COrbitNet.framework" \
 -output "$ROOT/Vendor/OrbitNet.xcframework"
