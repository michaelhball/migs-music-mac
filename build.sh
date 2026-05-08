#!/usr/bin/env bash
#
# Build a proper macOS .app bundle from the Swift sources.
#
# Why a custom script instead of just `swift build`: a SwiftPM executable produces a
# bare binary, but SwiftUI's MenuBarExtra needs a real .app bundle to behave correctly
# (status bar item, no Dock icon via LSUIElement, etc). This script:
#   1. Builds the Swift binary in release mode.
#   2. Lays out a Contents/MacOS + Contents/Resources structure.
#   3. Drops in Info.plist and the bash sync script.
#
# Output: dist/MigsMusicMac.app — drag into /Applications, double-click.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MigsMusicMac"
APP_BUNDLE="dist/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

echo "→ Cleaning previous bundle…"
rm -rf "${APP_BUNDLE}"

echo "→ Compiling release binary…"
swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)
BIN="${BIN_PATH}/${APP_NAME}"
if [[ ! -f "${BIN}" ]]; then
    echo "✗ swift build didn't produce ${BIN}. Check the output above." >&2
    exit 1
fi

echo "→ Assembling .app bundle…"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"

cp "${BIN}" "${CONTENTS}/MacOS/${APP_NAME}"
cp Info.plist "${CONTENTS}/Info.plist"
cp sync-playlist-to-phone.sh "${CONTENTS}/Resources/sync-playlist-to-phone.sh"
chmod +x "${CONTENTS}/Resources/sync-playlist-to-phone.sh"

# Bundle the migs-tracks CLI helper. The bash script invokes it instead of
# osascript for playlist track-list dumps — ITLibrary is ~5x faster and scales
# to 10k+ track playlists where AppleScript's per-track IPC becomes a real
# bottleneck.
TRACKS_BIN="${BIN_PATH}/migs-tracks"
if [[ -f "${TRACKS_BIN}" ]]; then
    cp "${TRACKS_BIN}" "${CONTENTS}/Resources/migs-tracks"
    chmod +x "${CONTENTS}/Resources/migs-tracks"
fi

# Optional: copy the AppleScript export tool for parity, even though the GUI doesn't use it.
cp export-playlist-as-m3u.applescript "${CONTENTS}/Resources/export-playlist-as-m3u.applescript"

# Bundle Sparkle.framework. The framework includes its own helper apps (Updater.app)
# and XPC services (Downloader.xpc, Installer.xpc) that handle the privileged install
# step — we copy the entire framework so all of that comes along. Use the prebuilt
# universal binary from the xcframework so the resulting .app runs on both Apple
# Silicon and Intel hardware.
SPARKLE_XCFRAMEWORK="$(find .build/artifacts -type d -name 'Sparkle.framework' -path '*/macos-arm64_x86_64/*' 2>/dev/null | head -1)"
if [[ -z "${SPARKLE_XCFRAMEWORK}" ]]; then
    echo "✗ Sparkle.framework not found under .build/artifacts. Did 'swift package resolve' run?" >&2
    exit 1
fi
mkdir -p "${CONTENTS}/Frameworks"
# -R preserves the symlinks inside Sparkle.framework (Versions/Current → Versions/B etc).
cp -R "${SPARKLE_XCFRAMEWORK}" "${CONTENTS}/Frameworks/"

# Re-sign the framework + its inner helpers ad-hoc so macOS doesn't refuse to load them.
# (Each macOS-distributable framework needs a valid signature; without this the bundled
# .app fails to launch with a code-signing error on Gatekeeper-strict configurations.)
codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime \
    --deep "${CONTENTS}/Frameworks/Sparkle.framework" 2>/dev/null || true

# Re-sign the main binary itself so its embedded reference to Sparkle.framework
# stays valid. Ad-hoc signing is enough for direct-download installs; once we add
# notarization we'll switch to a Developer ID identity.
codesign --force --sign - "${CONTENTS}/MacOS/${APP_NAME}" 2>/dev/null || true

echo ""
echo "✓ Built ${APP_BUNDLE}"
echo ""
echo "Next:"
echo "  open ${APP_BUNDLE}                 # try it now"
echo "  cp -R ${APP_BUNDLE} /Applications/  # install"
