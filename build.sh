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

echo ""
echo "✓ Built ${APP_BUNDLE}"
echo ""
echo "Next:"
echo "  open ${APP_BUNDLE}                 # try it now"
echo "  cp -R ${APP_BUNDLE} /Applications/  # install"
