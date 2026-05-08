#!/usr/bin/env bash
#
# bench-track-dump.sh — compare migs-tracks (ITLibrary CLI) against osascript
# at varying playlist sizes. No phone needed — exercises only the Mac-side path.
#
# Creates 3 throwaway playlists (10, 100, 1000 tracks), times each, cleans up.
# If the user's Music.app library has fewer than 1000 tracks the largest test
# silently caps at the library size.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Build release binary if needed.
if [[ ! -x .build/release/migs-tracks ]]; then
    swift build -c release --product migs-tracks >/dev/null
fi

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

bench() {
    local label="$1"; shift
    local start end elapsed
    start=$(now_ms)
    "$@" >/dev/null 2>&1 || true
    end=$(now_ms)
    elapsed=$((end - start))
    printf "  %-44s %5d ms\n" "$label" "$elapsed"
}

TMP_DIR=$(mktemp -d -t migs-bench-XXXX)
trap "rm -rf $TMP_DIR" EXIT

# ---- Create test playlists ----
echo "→ Creating test playlists in Music.app..."
CREATE_SCRIPT="$TMP_DIR/create.applescript"
cat > "$CREATE_SCRIPT" <<'EOSCRIPT'
on createPlaylist(plName, trackCount)
    tell application "Music"
        try
            delete user playlist plName
        end try
        set newPL to make new user playlist with properties {name:plName}
        set src to library playlist 1
        set allTracks to every file track of src
        set total to count of allTracks
        set toAdd to trackCount
        if toAdd > total then set toAdd to total
        repeat with i from 1 to toAdd
            try
                duplicate (item i of allTracks) to newPL
            end try
        end repeat
        return name of newPL
    end tell
end createPlaylist

on run argv
    my createPlaylist("migs-bench-10", 10)
    my createPlaylist("migs-bench-100", 100)
    my createPlaylist("migs-bench-1000", 1000)
end run
EOSCRIPT
osascript "$CREATE_SCRIPT" >/dev/null

# ---- Run the comparison ----
APPLE_SCRIPT="$TMP_DIR/dump.applescript"
cat > "$APPLE_SCRIPT" <<'EOSCRIPT'
on run argv
    set playlistName to item 1 of argv
    tell application "Music"
        try
            set thePlaylist to user playlist playlistName
        on error
            return ""
        end try
        set out to ""
        repeat with t in (every track of thePlaylist)
            try
                set fileLocation to POSIX path of (location of t as alias)
                set out to out & fileLocation & tab & ((artist of t) as string) & tab & ((name of t) as string) & tab & ((duration of t as integer) as text) & linefeed
            end try
        end repeat
        return out
    end tell
end run
EOSCRIPT

for sz in 10 100 1000; do
    pl="migs-bench-$sz"
    actual=$(osascript -e "tell application \"Music\" to count of tracks of user playlist \"$pl\"" 2>/dev/null || echo "?")
    echo ""
    echo "=== $pl ($actual tracks in Music.app) ==="
    bench "migs-tracks (ITLibrary CLI)" .build/release/migs-tracks "$pl"
    bench "osascript (AppleScript baseline)" osascript "$APPLE_SCRIPT" "$pl"
done

# ---- Cleanup ----
echo ""
echo "→ Deleting test playlists..."
DEL_SCRIPT="$TMP_DIR/delete.applescript"
cat > "$DEL_SCRIPT" <<'EOSCRIPT'
tell application "Music"
    repeat with plName in {"migs-bench-10", "migs-bench-100", "migs-bench-1000"}
        try
            delete user playlist plName
        end try
    end repeat
end tell
EOSCRIPT
osascript "$DEL_SCRIPT" >/dev/null

echo "Done."
