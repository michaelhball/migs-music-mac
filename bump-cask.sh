#!/usr/bin/env bash
#
# Updates Casks/migs-music.rb to point at the just-built release.
#
# Usage:
#   ./bump-cask.sh 0.2.0
#
# Reads the SHA256 from dist/migs-music-<version>.dmg.sha256 (produced by release.sh).
# Edits Casks/migs-music.rb in place to bump version + sha256. Doesn't commit — caller
# decides when to commit (release.sh --publish does it as part of the chain).

set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>" >&2
    exit 1
fi

CASK="Casks/migs-music.rb"
SHA_FILE="dist/migs-music-${VERSION}.dmg.sha256"

if [[ ! -f "$SHA_FILE" ]]; then
    echo "✗ $SHA_FILE not found. Run ./release.sh $VERSION first." >&2
    exit 1
fi

SHA256=$(cat "$SHA_FILE")
if [[ ${#SHA256} -ne 64 ]]; then
    echo "✗ $SHA_FILE looks malformed (expected 64-char SHA256, got '$SHA256')." >&2
    exit 1
fi

# In-place edits. The Cask file's `version "X"` and `sha256 "Y"` lines are uniquely
# identifiable by their leading two-space indent + keyword.
sed -i '' \
    -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"${SHA256}\"/" \
    "$CASK"

echo "✓ Updated $CASK:"
echo "    version $VERSION"
echo "    sha256  ${SHA256:0:16}…"
