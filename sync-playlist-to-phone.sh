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
#   4. Pushes the M3U last, to /sdcard/Music/<playlist>.m3u, where MIGS Music's
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

PLAYLIST_NAME="${1:-}"
if [[ -z "$PLAYLIST_NAME" ]]; then
    echo "Usage: $0 \"<playlist name>\"" >&2
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
M3U_OUT="$TMP_DIR/$PLAYLIST_NAME.m3u"

pushed=0
skipped=0
missing_local=0

echo "#EXTM3U" > "$M3U_OUT"

# 4. Walk the track list, pushing missing files and assembling the M3U.
# Read via file descriptor 3 so that `adb shell` / `adb push` calls inside the loop don't
# consume our stdin (which is the track list file). Without this, the very first adb call
# would gobble up the rest of the track list and the loop would silently terminate after
# one iteration.
while IFS=$'\t' read -r src_path artist title duration <&3; do
    if [[ ! -f "$src_path" ]]; then
        missing_local=$((missing_local + 1))
        continue
    fi

    # Compute the destination path on the phone.
    if [[ -n "$MAC_MUSIC_ROOT" && "$src_path" == "$MAC_MUSIC_ROOT/"* ]]; then
        rel_path="${src_path#$MAC_MUSIC_ROOT/}"
    else
        # File lives outside Music.app's managed library; just dump it at the root.
        rel_path=$(basename "$src_path")
    fi
    dest_path="$PHONE_MUSIC_ROOT/$rel_path"
    dest_dir=$(dirname "$dest_path")

    # Append M3U entry first (the on-phone path is what we want the M3U to reference).
    echo "#EXTINF:${duration:-0},$artist - $title" >> "$M3U_OUT"
    echo "$dest_path" >> "$M3U_OUT"

    # Check if the destination already exists. `[ -e ... ]` returns 0 on hit.
    # Quote dest_path with single-quotes for the remote shell since it may contain
    # spaces, parens, apostrophes — pass through with bash printf %q for safety.
    quoted_dest=$(printf '%q' "$dest_path")
    if adb shell "[ -e $quoted_dest ]" > /dev/null 2>&1; then
        skipped=$((skipped + 1))
    else
        # Make sure the parent dir exists, then push.
        quoted_dir=$(printf '%q' "$dest_dir")
        adb shell "mkdir -p $quoted_dir" > /dev/null
        # `adb push` handles spaces in the destination natively, no extra quoting needed.
        adb push "$src_path" "$dest_path" > /dev/null
        # adb push lands the file but Android's MediaStore won't read the ID3 tags from
        # it until something explicitly triggers MEDIA_SCANNER_SCAN_FILE. Without this,
        # the file appears in MediaStore with artist=NULL / title=filename and our M3U
        # matcher can't pair it with EXTINF metadata.
        adb shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://$quoted_dest" > /dev/null 2>&1
        pushed=$((pushed + 1))
        echo "  + $rel_path"
    fi
done 3< "$TRACK_LIST"

# 5. Push the M3U last so MIGS Music's auto-detect sees a complete playlist.
adb push "$M3U_OUT" "$PHONE_MUSIC_ROOT/$PLAYLIST_NAME.m3u" > /dev/null

echo ""
echo "✓ Done."
echo "  Pushed audio files:           $pushed"
echo "  Already on phone (skipped):   $skipped"
if (( missing_local > 0 )); then
    echo "  Missing local files:          $missing_local  (file moved or deleted on Mac)"
fi
echo ""
echo "On the phone: open MIGS Music → Playlists → tap Import on \"$PLAYLIST_NAME.m3u\"."
