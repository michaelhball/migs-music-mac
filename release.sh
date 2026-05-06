#!/usr/bin/env bash
#
# Build + package a versioned .dmg for distribution.
#
# Usage:
#   ./release.sh 0.1.0           # bump version + build + dmg + checksum
#   ./release.sh 0.1.0 --tag     # also create a `v0.1.0` git tag
#   ./release.sh                 # rebuild without bumping (uses current version)
#
# Output:
#   dist/MigsMusicMac.app            (rebuilt, ad-hoc signed)
#   dist/migs-music-<version>.dmg    (compressed, ready to upload to GitHub Releases)
#   dist/migs-music-<version>.dmg.sha256
#
# What this does NOT do:
#   - Notarize. Costs $99/yr Apple Developer account; without it, users see a
#     Gatekeeper warning on first launch they bypass with right-click → Open
#     (or `xattr -d com.apple.quarantine`). Acceptable for a free release.
#   - Push to GitHub. Run `gh release create v<ver> dist/migs-music-<ver>.dmg`
#     yourself once you've verified the .dmg locally.
#   - Update the Homebrew Cask. After uploading the .dmg, copy the SHA256 +
#     download URL into Casks/migs-music.rb in your homebrew-migs tap repo.
#     (Or: write a follow-up script that does it via the GitHub API.)

set -euo pipefail

cd "$(dirname "$0")"

VERSION=""
DO_TAG=false
DO_PUBLISH=false
APP_NAME="MigsMusicMac"
APP_BUNDLE="dist/${APP_NAME}.app"
INFO_PLIST="Info.plist"

# Arg parsing — the version is the only positional; --tag / --publish are flags.
for arg in "$@"; do
    case "$arg" in
        --tag) DO_TAG=true ;;
        --publish) DO_TAG=true; DO_PUBLISH=true ;;
        --*) echo "✗ Unknown flag: $arg" >&2; exit 1 ;;
        *) VERSION="$arg" ;;
    esac
done

if [[ -n "$VERSION" ]]; then
    echo "→ Bumping version to $VERSION..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
    # CFBundleVersion is a monotonic build counter — bump it as integer + suffix.
    CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
    NEW_BUILD=$((CURRENT_BUILD + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
    echo "→ Using current version: $VERSION"
fi

echo "→ Running build.sh..."
./build.sh

echo "→ Ad-hoc signing (no Apple Developer account required)..."
# Ad-hoc sign so the binary runs without complaint after the first Gatekeeper
# bypass; without ANY signature, every launch is rejected.
codesign --force --deep --sign - "$APP_BUNDLE"

echo "→ Verifying signature..."
codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 | head -8

DMG_NAME="migs-music-${VERSION}.dmg"
DMG_PATH="dist/${DMG_NAME}"
echo "→ Building $DMG_PATH..."
rm -f "$DMG_PATH"

# Use a temporary staging dir so the .dmg contains exactly the .app + a symlink to /Applications
# (a small UX nicety — drag the icon onto the Applications shortcut to install).
STAGING=$(mktemp -d)
trap "rm -rf $STAGING" EXIT
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Build a writable .dmg first so we can style the Finder window, then convert to a
# compressed read-only .dmg for distribution. UDRW = read-write; UDZO = compressed RO.
# Sized generously to accommodate the .app (~5 MB) + headroom for hidden Finder metadata.
# Path inside dist/ so we don't have to fight mktemp's extension handling — hdiutil
# silently appends `.dmg` if it's not already there.
WRITABLE_DMG="dist/migs-music-${VERSION}-writable.dmg"
rm -f "$WRITABLE_DMG"
trap 'rm -rf "$STAGING" "$WRITABLE_DMG"' EXIT
hdiutil create \
    -volname "migs music" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    -size 80m \
    "$WRITABLE_DMG" >/dev/null

# Mount the writable image. detach= explicit so we can hand the device id back to umount.
MOUNT_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$WRITABLE_DMG")
MOUNT_DEV=$(echo "$MOUNT_INFO" | head -1 | awk '{print $1}')
MOUNT_POINT=$(echo "$MOUNT_INFO" | tail -1 | awk '{print $3}')

# AppleScript window styling: bigger window, icon view, side-by-side .app + Applications.
# Cosmetic — if Finder doesn't cooperate (sandbox prompts, slow boot, etc.) we ship the
# unstyled .dmg rather than failing the whole release. `with timeout` plus `|| true`
# protects against the common "AppleEvent timed out" error on first run.
osascript <<APPLESCRIPT >/dev/null 2>&1 || echo "  (warning: Finder window styling skipped — .dmg is unstyled but still works)"
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

# Force a sync so the metadata changes hit disk before unmount.
sync

hdiutil detach "$MOUNT_DEV" -quiet 2>/dev/null || hdiutil detach "$MOUNT_DEV" -force -quiet

# Convert writable → compressed read-only.
hdiutil convert "$WRITABLE_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null

# SHA256 for the Homebrew Cask formula.
SHA_PATH="${DMG_PATH}.sha256"
shasum -a 256 "$DMG_PATH" | awk '{print $1}' > "$SHA_PATH"
SHA256=$(cat "$SHA_PATH")

echo ""
echo "✓ Release artefacts ready:"
echo "    $DMG_PATH"
echo "    $SHA_PATH"
echo ""
echo "Version:  $VERSION"
echo "SHA256:   $SHA256"
echo ""

if [[ "$DO_TAG" == true ]]; then
    if ! git diff --quiet "$INFO_PLIST"; then
        git add "$INFO_PLIST"
        git commit -m "Bump version to $VERSION"
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
        echo "✗ --publish requires the GitHub CLI (gh). Install it (brew install gh) and re-run." >&2
        exit 1
    fi
    echo "→ Pushing branch + tags..."
    git push
    git push --tags
    echo "→ Creating GitHub release v$VERSION..."
    if gh release view "v$VERSION" >/dev/null 2>&1; then
        echo "  Release v$VERSION already exists; uploading asset..."
        gh release upload "v$VERSION" "$DMG_PATH" --clobber
    else
        gh release create "v$VERSION" "$DMG_PATH" \
            --title "v$VERSION" \
            --notes "Release v$VERSION. See commit log for changes."
    fi
    echo "→ Bumping Cask formula..."
    ./bump-cask.sh "$VERSION"
    git add Casks/migs-music.rb
    git commit -m "migs-music $VERSION (Cask)"
    git push
    echo ""
    echo "✓ Published v$VERSION."
    echo "  Don't forget to copy Casks/migs-music.rb to your homebrew-migs tap repo:"
    echo "    cp Casks/migs-music.rb ~/projects/homebrew-migs/Casks/migs-music.rb"
    echo "    (cd ~/projects/homebrew-migs && git add . && git commit -m 'migs-music $VERSION' && git push)"
else
    cat <<EOF

Next steps:
  1. Test the .dmg locally:
       open "$DMG_PATH"
  2. Run with --publish to push, create GitHub release, bump the Cask in one shot:
       ./release.sh $VERSION --publish
EOF
fi
