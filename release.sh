#!/usr/bin/env bash
#
# Cut a release: build the .app, package it into a DMG with Finder styling, sign
# the DMG with the Sparkle EdDSA key, and append an entry to appcast.xml so
# existing installs see the update on their next Sparkle check.
#
# Usage:
#   ./release.sh 0.2.0           # bump + build + dmg + sign + appcast
#   ./release.sh 0.2.0 --tag     # also commit + git tag
#   ./release.sh 0.2.0 --publish # also push + gh release create + upload DMG
#   ./release.sh                 # rebuild without bumping (uses current version)
#
# Output:
#   dist/MigsMusicMac.app
#   dist/migs-music-<version>.dmg
#   dist/migs-music-<version>.dmg.sha256
#   appcast.xml (updated in place)
#
# What this does NOT do:
#   - Notarize. We don't have a $99 Apple Dev account; first-launch users see a
#     Gatekeeper warning they bypass with right-click → Open. Sparkle's auto-update
#     path swaps the .app bundle in-place which generally doesn't re-trigger
#     Gatekeeper, but this is worth validating on a fresh non-dev Mac before
#     trusting it to land transparently.
#
# Prerequisites:
#   - Sparkle EdDSA private key in macOS Keychain (search "https://sparkle-project.org",
#     account "ed25519"). Backup notes: workspace/SPARKLE_BACKUPS.md.
#   - gh CLI authenticated (only for --publish).

set -euo pipefail

cd "$(dirname "$0")"

VERSION=""
DO_TAG=false
DO_PUBLISH=false
APP_NAME="MigsMusicMac"
APP_BUNDLE="dist/${APP_NAME}.app"
INFO_PLIST="Info.plist"
APPCAST="appcast.xml"

for arg in "$@"; do
    case "$arg" in
        --tag) DO_TAG=true ;;
        --publish) DO_TAG=true; DO_PUBLISH=true ;;
        --*) echo "✗ Unknown flag: $arg" >&2; exit 1 ;;
        *) VERSION="$arg" ;;
    esac
done

# Validate version format. Sparkle uses these for ordering, so a typo is a real bug.
if [[ -n "$VERSION" ]] && ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ Version must be MAJOR.MINOR.PATCH (e.g. 0.1.1). Got: $VERSION" >&2
    exit 1
fi

if [[ -n "$VERSION" ]]; then
    echo "→ Bumping version to $VERSION..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
    CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
    NEW_BUILD=$((CURRENT_BUILD + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
    NEW_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
    echo "→ Using current version: $VERSION (build $NEW_BUILD)"
fi

echo "→ Running build.sh..."
./build.sh

# build.sh ad-hoc signs the framework + main binary already; explicit re-sign here
# guarantees the DMG contents match what Sparkle will sign-update.
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

DMG_NAME="migs-music-${VERSION}.dmg"
DMG_PATH="dist/${DMG_NAME}"
echo "→ Building $DMG_PATH..."
rm -f "$DMG_PATH"

# Stage the .app + an /Applications shortcut into a temp dir, build a writable DMG,
# style its Finder window, then convert to a compressed read-only DMG for distribution.
STAGING=$(mktemp -d)
WRITABLE_DMG="dist/migs-music-${VERSION}-writable.dmg"
trap 'rm -rf "$STAGING" "$WRITABLE_DMG"' EXIT
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$WRITABLE_DMG"
hdiutil create \
    -volname "migs music" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    -size 80m \
    "$WRITABLE_DMG" >/dev/null

MOUNT_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$WRITABLE_DMG")
MOUNT_DEV=$(echo "$MOUNT_INFO" | head -1 | awk '{print $1}')

# Cosmetic Finder styling — silently skipped if AppleEvents misbehave.
osascript >/dev/null 2>&1 <<'APPLESCRIPT' || echo "  (warning: Finder window styling skipped)"
with timeout of 60 seconds
    tell application "Finder"
        tell disk "migs music"
            open
            delay 2
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 100, 800, 460}
            set theViewOptions to the icon view options of container window
            set arrangement of theViewOptions to not arranged
            set icon size of theViewOptions to 96
            set position of item "MigsMusicMac.app" of container window to {160, 180}
            set position of item "Applications" of container window to {440, 180}
            update without registering applications
            delay 1
            close
        end tell
    end tell
end timeout
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DEV" -quiet 2>/dev/null || hdiutil detach "$MOUNT_DEV" -force -quiet
hdiutil convert "$WRITABLE_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null

# SHA256 for the GitHub release page.
SHA_PATH="${DMG_PATH}.sha256"
shasum -a 256 "$DMG_PATH" | awk '{print $1}' > "$SHA_PATH"
SHA256=$(cat "$SHA_PATH")

# Sparkle EdDSA signature for the DMG. The output is a string with two attributes
# (sparkle:edSignature="…" length="…") that we paste verbatim into the appcast.
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ ! -x "$SIGN_TOOL" ]]; then
    echo "✗ sign_update not found at $SIGN_TOOL. Run 'swift package resolve' first." >&2
    exit 1
fi
echo "→ Signing DMG with EdDSA key..."
# Default: sign_update reads the private key from the macOS Keychain (where
# generate_keys stored it). On CI runners we have no Keychain access, so the
# workflow drops the secret value into a file and exports SPARKLE_ED_KEY_FILE
# pointing at it. Honour that here, falling through to Keychain otherwise.
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
    SIGN_OUTPUT=$("$SIGN_TOOL" -f "$SPARKLE_ED_KEY_FILE" "$DMG_PATH")
else
    SIGN_OUTPUT=$("$SIGN_TOOL" "$DMG_PATH")
fi

# Update appcast.xml. Initialise on first run if it doesn't exist.
PUB_DATE=$(LC_TIME=en_US.UTF-8 date "+%a, %d %b %Y %H:%M:%S %z")
DMG_SIZE=$(stat -f%z "$DMG_PATH")
DOWNLOAD_URL="https://github.com/michaelhball/migs-music-mac/releases/download/v${VERSION}/${DMG_NAME}"

if [[ ! -f "$APPCAST" ]]; then
    cat > "$APPCAST" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>migs music Mac</title>
        <link>https://michaelhball.github.io/migs-music-mac/appcast.xml</link>
        <description>Updates for migs music on macOS.</description>
        <language>en</language>
    </channel>
</rss>
EOF
fi

# Insert the new <item> right after <language>. Newest entry first — Sparkle picks
# the highest version regardless of order, but humans reading the file expect chronological.
NEW_ITEM=$(cat <<EOF
        <item>
            <title>migs music ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${NEW_BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure url="${DOWNLOAD_URL}" type="application/octet-stream" ${SIGN_OUTPUT} />
        </item>
EOF
)

awk -v item="$NEW_ITEM" '
    /<\/language>/ { print; print item; next }
    { print }
' "$APPCAST" > "${APPCAST}.tmp" && mv "${APPCAST}.tmp" "$APPCAST"

echo ""
echo "✓ Release artefacts ready:"
echo "    $DMG_PATH"
echo "    $SHA_PATH"
echo "    $APPCAST (updated)"
echo ""
echo "Version:  $VERSION (build $NEW_BUILD)"
echo "SHA256:   $SHA256"
echo ""

if [[ "$DO_TAG" == true ]]; then
    if ! git diff --quiet "$INFO_PLIST" "$APPCAST"; then
        git add "$INFO_PLIST" "$APPCAST"
        git commit -m "Release $VERSION"
    fi
    if git rev-parse "v$VERSION" >/dev/null 2>&1; then
        echo "→ Tag v$VERSION already exists; skipping git tag."
    else
        git tag "v$VERSION"
        echo "✓ Tagged v$VERSION"
    fi
fi

if [[ "$DO_PUBLISH" == true ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "✗ --publish requires gh CLI (brew install gh)." >&2
        exit 1
    fi
    git push
    git push --tags
    if gh release view "v$VERSION" >/dev/null 2>&1; then
        echo "  Release v$VERSION already exists; uploading asset..."
        gh release upload "v$VERSION" "$DMG_PATH" --clobber
    else
        gh release create "v$VERSION" "$DMG_PATH" \
            --title "v$VERSION" \
            --notes "Release v$VERSION. See commit log for changes."
    fi
    echo ""
    echo "✓ Published v$VERSION."
    echo "  Once GitHub Pages serves the updated appcast.xml, existing installs"
    echo "  see the update on their next daily Sparkle check (or instantly via the"
    echo "  in-app version-label button)."
else
    cat <<EOF

Next steps:
  1. Test the .dmg locally:
       open "$DMG_PATH"
  2. Inspect the appcast entry in $APPCAST.
  3. To publish, push + create the GitHub release + upload the DMG in one shot:
       ./release.sh $VERSION --publish
EOF
fi
