#!/bin/bash
# Install from a durable source checkout. All prompts for secrets belong to macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
[[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]] || { echo 'Orbit’s source installer needs an Apple silicon Mac.' >&2; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo 'Run Orbit Setup as the logged-in Mac user.' >&2; exit 1; }

# A linked worktree cannot own the persistent checkout recorded in the installed app.
[[ "$(git rev-parse --path-format=absolute --git-common-dir)" == "$(pwd -P)/.git" ]] || { echo 'Run scripts/install.sh from the primary Orbit checkout.' >&2; exit 1; }

# LaunchServices and standard scripting additions work before full Xcode is installed.
check_again() {
  /usr/bin/osascript -e 'on run argv
    display dialog (item 1 of argv) with title "Orbit Setup" buttons {"Cancel", "Check Again"} default button "Check Again"
  end run' "$1" >/dev/null
}
admin() {
  /usr/bin/osascript -e 'on run argv
    set cmd to ""
    repeat with arg in argv
      set cmd to cmd & " " & quoted form of (contents of arg)
    end repeat
    do shell script cmd with administrator privileges
  end run' "$@"
}
ensure_brew() {
  command -v brew >/dev/null && return
  # Homebrew's signed macOS installer works from an agent without an interactive tty.
  local pkg
  pkg="$scratch/Homebrew.pkg"
  curl -fLsS --retry 2 "https://github.com/Homebrew/brew/releases/latest/download/Homebrew.pkg" -o "$pkg"
  /usr/sbin/spctl --assess --type install "$pkg"
  admin /usr/sbin/installer -pkg "$pkg" -target /
  command -v brew >/dev/null
}
find_xcode() {
  local dev version
  for dev in "${DEVELOPER_DIR:-}" "$(xcode-select -p 2>/dev/null || true)" /Applications/Xcode*.app/Contents/Developer "$HOME"/Applications/Xcode*.app/Contents/Developer; do
    if [[ "$dev" == *.app ]]; then dev="$dev/Contents/Developer"; fi
    [[ -d "$dev/Platforms/iPhoneOS.platform" ]] || continue
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dev/../Info.plist")"
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]] && (( BASH_REMATCH[1] > 26 || (BASH_REMATCH[1] == 26 && BASH_REMATCH[2] >= 2) )); then
      export DEVELOPER_DIR="$dev"
      return 0
    fi
  done
  return 1
}
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
if ! find_xcode; then
  ensure_brew
  command -v mas >/dev/null || brew install mas
  while ! admin "$(command -v mas)" get 497799835 || ! find_xcode; do
    open 'macappstore://itunes.apple.com/app/id497799835'
    check_again 'Sign in to the App Store for Xcode. If your Mac needs an older release, install a compatible Xcode 26.2 or later and check again.'
    if find_xcode; then break; fi
  done
fi
if ! /usr/bin/xcodebuild -license check >/dev/null 2>&1; then
  open "${DEVELOPER_DIR%/Contents/Developer}"
  until /usr/bin/xcodebuild -license check >/dev/null 2>&1; do check_again 'Review the Xcode license in Xcode, then check again.'; done
fi
if ! /usr/bin/xcodebuild -checkFirstLaunchStatus; then
  admin /usr/bin/env "DEVELOPER_DIR=$DEVELOPER_DIR" /usr/bin/xcodebuild -runFirstLaunch
fi
# The pinned device library has both iOS and tvOS slices.
for platform in iOS tvOS; do
  sdk=iphoneos
  [[ "$platform" != tvOS ]] || sdk=appletvos
  /usr/bin/xcrun --sdk "$sdk" --show-sdk-path >/dev/null 2>&1 || /usr/bin/xcodebuild -downloadPlatform "$platform"
done
if ! command -v go >/dev/null; then ensure_brew; brew install go; fi
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then ensure_brew; brew install python; fi
if ! scripts/iroh/build_iroh_direct.sh "$PWD/Vendor/IrohDirect" --check; then
  if ! command -v rustup >/dev/null; then
    ensure_brew
    brew install rustup
  fi
  export RUSTUP_TOOLCHAIN=stable
  rustup toolchain install stable --profile minimal
  rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  # Homebrew may expose rustup without its cargo/rustc proxies.
  ORBIT_CARGO="$(rustup which cargo)"
  RUSTC="$(rustup which rustc)"
  export ORBIT_CARGO RUSTC
fi
ORBIT_MAC_SIGNING_IDENTITY="$(python3 scripts/agent_identity.py)"
export ORBIT_MAC_SIGNING_IDENTITY
scripts/build_and_run.sh --agent-setup
