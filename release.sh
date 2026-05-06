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

VERSION="${1:-}"
TAG_FLAG="${2:-}"
APP_NAME="MigsMusicMac"
APP_BUNDLE="dist/${APP_NAME}.app"
INFO_PLIST="Info.plist"

if [[ -n "$VERSION" && "$VERSION" == --* ]]; then
    echo "✗ First arg should be a version like 0.1.0, not a flag." >&2
    exit 1
fi

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

hdiutil create \
    -volname "migs music" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

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

if [[ "$TAG_FLAG" == "--tag" ]]; then
    if ! git diff --quiet "$INFO_PLIST"; then
        git add "$INFO_PLIST"
        git commit -m "Bump version to $VERSION"
    fi
    git tag "v$VERSION"
    echo "✓ Tagged v$VERSION (push with: git push --tags)"
fi

cat <<EOF

Next steps:
  1. Test the .dmg locally:
       open "$DMG_PATH"
  2. Upload to GitHub Releases:
       gh release create v$VERSION "$DMG_PATH" \\
         --title "v$VERSION" --notes "Release notes here"
  3. Update Homebrew Cask formula (Casks/migs-music.rb in your tap):
       version "$VERSION"
       sha256 "$SHA256"
  4. Bump the URL inside the Cask to the new release.
EOF
