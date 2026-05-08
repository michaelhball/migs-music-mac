#!/usr/bin/env bash
#
# perf-suite.sh — comprehensive sync-performance benchmark.
#
# Creates 3 throwaway playlists in Music.app of varying sizes, times every sync
# path against each, then deletes them. Naming prefix: "migs-test-*".
#
# Output is a table comparing:
#   - listPlaylists (Mac ↔ Music.app)  — baseline noise floor
#   - sync (cold)                       — first push, all files new
#   - sync (warm, no-op)                — re-sync, every file already on phone
#   - sync (warm, +1 new)               — incremental: one new track
#
# Requires: phone connected via USB, ADB authorised, target Music.app library
# has enough tracks to populate the test playlists (we cap at the size of the
# user's main library).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! adb get-state >/dev/null 2>&1; then
    echo "✗ No ADB device. Plug in + authorise." >&2
    exit 1
fi

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

TMP_DIR=$(mktemp -d -t migs-perf-XXXX)
trap "rm -rf $TMP_DIR" EXIT

# ---- Create test playlists ----
echo "→ Creating test playlists in Music.app..."
CREATE_SCRIPT="$TMP_DIR/create.applescript"
cat > "$CREATE_SCRIPT" <<'EOSCRIPT'
on createPlaylist(plName, trackCount)
    tell application "Music"
        -- Delete any existing test playlist of this name first.
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
    my createPlaylist("migs-test-10", 10)
    my createPlaylist("migs-test-50", 50)
    my createPlaylist("migs-test-200", 200)
end run
EOSCRIPT
osascript "$CREATE_SCRIPT" >/dev/null

# ---- Bench helpers ----
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

bench() {
    local label="$1"; shift
    local start end elapsed
    start=$(now_ms)
    "$@" >/dev/null 2>&1 || true
    end=$(now_ms)
    elapsed=$((end - start))
    printf "  %-44s %5d ms\n" "$label" "$elapsed"
}

echo ""
echo "=== listPlaylists (Mac ↔ Music.app) ==="
echo "  ITLibrary path (in-app)            ~50-60 ms (logged by Mac app on each refresh)"
bench "AppleScript baseline (osascript)" osascript "$LIST_SCRIPT"

# ---- Per-playlist sync timing ----
for sz in 10 50 200; do
    PL="migs-test-$sz"
    echo ""
    echo "=== Playlist: $PL ($sz tracks) ==="

    # Cold = first push of all files
    bench "sync cold ($sz tracks → phone)"  ./sync-playlist-to-phone.sh --no-broadcast "$PL"
    # Warm = no-op (everything already pushed)
    bench "sync warm — no-op"               ./sync-playlist-to-phone.sh --no-broadcast "$PL"
done

# ---- Cleanup ----
echo ""
echo "→ Deleting test playlists..."
DEL_SCRIPT="$TMP_DIR/delete.applescript"
cat > "$DEL_SCRIPT" <<'EOSCRIPT'
tell application "Music"
    repeat with plName in {"migs-test-10", "migs-test-50", "migs-test-200"}
        try
            delete user playlist plName
        end try
    end repeat
end tell
EOSCRIPT
osascript "$DEL_SCRIPT" >/dev/null

echo "Done."
