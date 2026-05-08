#!/usr/bin/env bash
#
# perf-test.sh — measure both sync paths end-to-end with timing.
#
# Tests:
#   1. Mac ↔ Music.app: time the listPlaylists AppleScript (cold + hot).
#   2. Mac → phone: time the full sync-playlist-to-phone.sh on a small playlist
#      with all songs already on phone (skip-only path).
#   3. Mac → phone: add a track via AppleScript, time the sync again
#      (should detect ONE new file, push it, leave the rest skipped).
#
# Requires: phone connected via USB, ADB authorised, target playlist
# already synced (run a normal sync first if you haven't).

set -euo pipefail

PLAYLIST_NAME="${1:-doot}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! adb get-state >/dev/null 2>&1; then
    echo "✗ No ADB device. Plug in + authorise." >&2
    exit 1
fi

# Use Python for ms-resolution timing — BSD `date` on macOS doesn't support %N.
now_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

timeit() {
    local label="$1"; shift
    local start end elapsed
    start=$(now_ms)
    "$@" >/dev/null 2>&1 || true
    end=$(now_ms)
    elapsed=$((end - start))
    printf "  %-42s %5d ms\n" "$label" "$elapsed"
}

# Write the listPlaylists AppleScript to a temp file once — measuring the same
# script body each call.
TMP_DIR=$(mktemp -d -t migs-perf-XXXX)
trap "rm -rf $TMP_DIR" EXIT
LIST_SCRIPT="$TMP_DIR/list.applescript"
cat > "$LIST_SCRIPT" <<'EOSCRIPT'
tell application "Music"
    set out to ""
    repeat with p in (every user playlist)
        try
            set out to out & ((count of tracks of p) as text) & tab & (name of p as text) & linefeed
        end try
    end repeat
    return out
end tell
EOSCRIPT

echo "=== 1. Mac ↔ Music.app (listPlaylists AppleScript) ==="
timeit "cold (first call after build)" osascript "$LIST_SCRIPT"
timeit "hot (second call)" osascript "$LIST_SCRIPT"
timeit "hot (third call)" osascript "$LIST_SCRIPT"
echo ""

echo "=== 2. Mac → phone: re-sync (all already on phone) ==="
timeit "sync (skip-only path)" ./sync-playlist-to-phone.sh --no-broadcast "$PLAYLIST_NAME"
echo ""

# Add a track via AppleScript: pick any track from the main library that's not
# already in the target playlist, duplicate it in.
echo "=== 3. Mac → phone: add a track, sync again ==="
ADD_SCRIPT="$TMP_DIR/add.applescript"
cat > "$ADD_SCRIPT" <<EOSCRIPT
tell application "Music"
    try
        set thePlaylist to user playlist "$PLAYLIST_NAME"
    on error
        return "ERROR: no playlist named $PLAYLIST_NAME"
    end try
    set existingIds to {}
    repeat with t in (every track of thePlaylist)
        set end of existingIds to (database ID of t)
    end repeat
    set candidate to missing value
    repeat with t in (every file track of library playlist 1)
        if (database ID of t) is not in existingIds then
            set candidate to t
            exit repeat
        end if
    end repeat
    if candidate is missing value then
        return "ERROR: no candidate track found"
    end if
    duplicate candidate to thePlaylist
    return (name of candidate) as string
end tell
EOSCRIPT
ADD_RESULT=$(osascript "$ADD_SCRIPT" 2>&1 || echo "ERROR")
echo "  Added track: $ADD_RESULT"
timeit "sync (1 new file path)" ./sync-playlist-to-phone.sh --no-broadcast "$PLAYLIST_NAME"
echo ""

echo "=== 4. listPlaylists picks up the new count ==="
timeit "listPlaylists after edit" osascript "$LIST_SCRIPT"
osascript "$LIST_SCRIPT" | sed 's/^/    /'
echo ""

echo "Done."
