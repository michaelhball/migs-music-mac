#!/usr/bin/env bash
#
# sync-playlist-to-phone.sh — push a Music.app playlist + its audio files to a phone.
#
# Usage:
#   scripts/sync-playlist-to-phone.sh "My Playlist"
#
# What it does:
#   1. Asks Music.app for every track in the named playlist (via AppleScript).
#   2. Mirrors Music.app's Artist/Album/Track layout under /sdcard/Music/ on the phone,
#      preserving relative paths from ~/Music/Music/Media.localized/Music/ (or
#      $HOME/Music/Music/Media/Music/ depending on your macOS version).
#   3. For each track, checks whether the destination already exists on the phone —
#      pushes only the missing ones (so re-syncing a playlist that overlaps with
#      already-transferred music is effectively free).
#   4. Pushes the M3U last, to /sdcard/Music/<playlist>.m3u, where migs music's
#      auto-detect picks it up.
#
# Requirements:
#   - macOS with Music.app
#   - Phone connected via USB with ADB authorised (`adb devices` should show one device)
#   - First run will trigger a macOS prompt to allow Terminal to control Music.app — say yes.
#
# Streaming-only Apple Music tracks (no local file) are silently skipped: they wouldn't
# be playable on the phone anyway since the audio file isn't on disk.

set -euo pipefail

BROADCAST_ON_DONE=true
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-broadcast)
            BROADCAST_ON_DONE=false
            ;;
        *)
            ARGS+=("$arg")
            ;;
    esac
done

PLAYLIST_NAME="${ARGS[0]:-}"
if [[ -z "$PLAYLIST_NAME" ]]; then
    echo "Usage: $0 [--no-broadcast] \"<playlist name>\"" >&2
    exit 1
fi

# 1. Verify ADB device.
if ! adb get-state > /dev/null 2>&1; then
    echo "✗ No ADB device. Is the phone plugged in and authorised? (Try: adb devices)" >&2
    exit 1
fi

# 2. Verify the playlist exists in Music.app, and grab its tracks.
TMP_DIR=$(mktemp -d -t migs-sync-XXXX)
trap "rm -rf $TMP_DIR" EXIT
TRACK_LIST="$TMP_DIR/tracks.tsv"

# AppleScript dumps one TSV row per track: <posix path>\t<artist>\t<title>\t<duration>
# Tracks without a local file are skipped (try/end try around `location of`).
osascript - "$PLAYLIST_NAME" "$TRACK_LIST" <<'APPLESCRIPT'
on run argv
    set playlistName to item 1 of argv
    set outPath to item 2 of argv
    tell application "Music"
        try
            set thePlaylist to user playlist playlistName
        on error
            error "No playlist named \"" & playlistName & "\""
        end try
        set outFile to open for access (POSIX file outPath) with write permission
        set eof of outFile to 0
        repeat with t in (every track of thePlaylist)
            try
                set fileLocation to POSIX path of (location of t as alias)
                set artistName to (artist of t) as string
                set trackName to (name of t) as string
                -- Duration coercion fails on some tracks where Music.app reports it as a
                -- type `round` won't accept; fall back to -1 (M3U "unknown" convention)
                -- rather than skipping the whole row.
                set durationSec to -1
                try
                    set durationSec to (duration of t as integer)
                end try
                write fileLocation & tab & artistName & tab & trackName & tab & durationSec & linefeed to outFile
            end try
        end repeat
        close access outFile
    end tell
end run
APPLESCRIPT

if [[ ! -s "$TRACK_LIST" ]]; then
    echo "✗ Playlist \"$PLAYLIST_NAME\" produced no playable tracks (empty playlist, or all tracks are streaming-only)." >&2
    exit 1
fi

TRACK_COUNT=$(wc -l < "$TRACK_LIST" | tr -d ' ')
echo "→ \"$PLAYLIST_NAME\": $TRACK_COUNT tracks with local files."

# 3. Discover the Music.app media root so we can compute clean relative paths.
#    Modern macOS:   ~/Music/Music/Media.localized/Music/
#    Some installs:  ~/Music/Music/Media/Music/
MAC_MUSIC_ROOT=""
for candidate in \
    "$HOME/Music/Music/Media.localized/Music" \
    "$HOME/Music/Music/Media/Music"; do
    if [[ -d "$candidate" ]]; then
        MAC_MUSIC_ROOT="$candidate"
        break
    fi
done

PHONE_MUSIC_ROOT="/sdcard/Music"
PHONE_SYNC_DIR="/sdcard/Android/media/com.migsmusic/sync"
adb shell "mkdir -p '$PHONE_SYNC_DIR'" > /dev/null
M3U_OUT="$TMP_DIR/$PLAYLIST_NAME.m3u"
STAGE_DIR="$TMP_DIR/stage"
mkdir -p "$STAGE_DIR"

pushed=0
skipped=0
missing_local=0

# 4a. Inventory the phone in ONE roundtrip. The previous version did one
#     `adb shell [ -e PATH ]` per track — for a 10k-library that's ~10–30 minutes of
#     pure roundtrip overhead. One `find` + a local awk hash is O(N+M) and runs in
#     under a second for any realistic library size.
PHONE_FILES="$TMP_DIR/phone_files.txt"
phone_inventory_start=$(date +%s)
adb shell "find $PHONE_MUSIC_ROOT -type f 2>/dev/null" > "$PHONE_FILES" || true
phone_inventory_secs=$(( $(date +%s) - phone_inventory_start ))
phone_count=$(wc -l < "$PHONE_FILES" | tr -d ' ')
echo "→ Phone inventory: $phone_count file(s) (${phone_inventory_secs}s)"

# 4b. Decide push-or-skip per track using awk for an O(N+M) hash lookup. Awk also
#     computes the dest_path that would land on the phone — keeps that logic in one
#     place rather than duplicating it in bash. Output columns:
#       src \t dest \t rel \t artist \t title \t duration \t status (SKIP|PUSH)
DECISIONS="$TMP_DIR/decisions.tsv"
awk -F'\t' \
    -v phone_file="$PHONE_FILES" \
    -v music_root="$MAC_MUSIC_ROOT" \
    -v phone_root="$PHONE_MUSIC_ROOT" \
    '
    BEGIN {
        while ((getline line < phone_file) > 0) on_phone[line] = 1
        close(phone_file)
    }
    {
        src = $1; artist = $2; title = $3; duration = $4
        if (music_root != "" && index(src, music_root "/") == 1) {
            rel = substr(src, length(music_root) + 2)
        } else {
            n = split(src, parts, "/"); rel = parts[n]
        }
        dest = phone_root "/" rel
        status = (dest in on_phone) ? "SKIP" : "PUSH"
        print src "\t" dest "\t" rel "\t" artist "\t" title "\t" duration "\t" status
    }
    ' "$TRACK_LIST" > "$DECISIONS"

# 4c. Build the M3U in track order. For PUSH rows, also stage a symlink in $STAGE_DIR
#     mirroring the desired layout under /sdcard/Music — `adb push` follows symlinks,
#     so this is zero-copy locally.
echo "#EXTM3U" > "$M3U_OUT"
while IFS=$'\t' read -r src dest rel artist title duration status; do
    if [[ ! -f "$src" ]]; then
        missing_local=$((missing_local + 1))
        continue
    fi
    echo "#EXTINF:${duration:-0},$artist - $title" >> "$M3U_OUT"
    echo "$dest" >> "$M3U_OUT"
    case "$status" in
        SKIP)
            skipped=$((skipped + 1))
            ;;
        PUSH)
            stage_target="$STAGE_DIR/$rel"
            mkdir -p "$(dirname "$stage_target")"
            ln -sf "$src" "$stage_target"
            pushed=$((pushed + 1))
            echo "  + $rel"
            ;;
    esac
done < "$DECISIONS"

# 4d. Bulk push everything that needs pushing in one adb session. Per-file
#     `adb push` had ~50-200ms session overhead PER FILE; with hundreds of new
#     tracks that's all roundtrip time we never had to pay. One push of the staging
#     tree transfers everything in a single session.
if (( pushed > 0 )); then
    push_start=$(date +%s)
    adb push "$STAGE_DIR/" "$PHONE_MUSIC_ROOT/" > /dev/null
    push_secs=$(( $(date +%s) - push_start ))
    echo "→ Pushed $pushed file(s) in ${push_secs}s"
fi

# 5. Push the M3U last so migs music's auto-detect sees a complete playlist.
# M3U lands in the app's media dir (not /sdcard/Music) — Android 11+ refuses to grant
# SAF access to /sdcard/Music, but /sdcard/Android/media/<package>/ is owned by us and
# needs no permission.
M3U_DEST="$PHONE_SYNC_DIR/$PLAYLIST_NAME.m3u"
adb push "$M3U_OUT" "$M3U_DEST" > /dev/null

# 6. Trigger migs music's auto-import without requiring the user to open the app or visit
#    the Playlists tab. The receiver is manifest-declared so this wakes the app from cold
#    if needed; the import runs in well under a second. -f 0x20 sets
#    FLAG_INCLUDE_STOPPED_PACKAGES so the broadcast also reaches the app when it's been
#    force-stopped (fresh install, system kill, Settings → force stop) — without it, the
#    receiver is silently skipped and the user has to open the app to trigger import manually.
#
# When invoked via the Mac orchestrator (`--no-broadcast`), the orchestrator pushes the
# manifest and broadcasts ONCE at the end of all per-playlist syncs — the receiver then
# does all imports + per-song orphan cleanup + whole-playlist prune in a single atomic
# pass. Per-playlist broadcasting in that flow would race with the still-unwritten
# manifest and miss the deleteOrphans flag.
imported_on_phone=true
if [[ "$BROADCAST_ON_DONE" == true ]]; then
    adb shell "am broadcast -a com.migsmusic.AUTO_IMPORT -p com.migsmusic -f 0x20" > /dev/null 2>&1 || true

    # Wait briefly for the phone to consume the M3U. The auto-import deletes the file on
    # success — we poll for its absence so the Mac UI can confirm "imported, not just
    # pushed". Bounded at ~5s; if still there after that, the Mac caller surfaces
    # "pushed but not yet imported".
    imported_on_phone=false
    quoted_m3u=$(printf '%q' "$M3U_DEST")
    for _ in $(seq 1 10); do
        if ! adb shell "[ -e $quoted_m3u ]" > /dev/null 2>&1; then
            imported_on_phone=true
            break
        fi
        sleep 0.5
    done
fi

echo ""
if [[ "$BROADCAST_ON_DONE" == false ]]; then
    echo "✓ Pushed (orchestrator will broadcast at end)."
elif [[ "$imported_on_phone" == true ]]; then
    echo "✓ Synced. Phone has imported \"$PLAYLIST_NAME\"."
else
    echo "⚠ Pushed, but phone hasn't auto-imported within 5s."
    echo "  Open migs music to trigger the import manually."
fi
echo "  Pushed audio files:           $pushed"
echo "  Already on phone (skipped):   $skipped"
if (( missing_local > 0 )); then
    echo "  Missing local files:          $missing_local  (file moved or deleted on Mac)"
fi
