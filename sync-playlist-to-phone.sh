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

# 2. Dump the playlist's track list as TSV. We prefer `migs-tracks` (a Swift
#    CLI helper that uses iTunesLibrary.framework) — same shape, ~5x faster than
#    osascript, and the speedup actually scales: ITLibrary is constant cost
#    regardless of playlist size, while AppleScript spends per-track AppleEvent
#    IPC on the order of ms. For 1000-track playlists, AppleScript takes ~5–10s;
#    migs-tracks stays at ~250ms.
#
# Falls back to AppleScript if the helper isn't available (e.g., running from a
# pre-bundled checkout without `swift build`). Same TSV shape either way.
TMP_DIR=$(mktemp -d -t migs-sync-XXXX)
trap "rm -rf $TMP_DIR" EXIT
TRACK_LIST="$TMP_DIR/tracks.tsv"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGS_TRACKS=""
for candidate in \
    "$SCRIPT_DIR/migs-tracks" \
    "$SCRIPT_DIR/.build/release/migs-tracks" \
    "$SCRIPT_DIR/.build/debug/migs-tracks"; do
    if [[ -x "$candidate" ]]; then
        MIGS_TRACKS="$candidate"
        break
    fi
done

if [[ -n "$MIGS_TRACKS" ]]; then
    "$MIGS_TRACKS" "$PLAYLIST_NAME" --out "$TRACK_LIST" || true
else
    # AppleScript fallback. Same output shape: <posix path>\t<artist>\t<title>\t<duration>
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
fi

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
#
#     We capture filesize alongside path so the dedup step below can match by
#     (size, basename) instead of full-path equality. That handles the "song
#     transferred via OnePlus Share lives at a different path than what we'd
#     compute" case — same filename + same byte count = treat it as already on
#     phone, point the M3U at the existing path, don't re-push.
PHONE_FILES="$TMP_DIR/phone_files.tsv"
phone_inventory_start=$(date +%s)
# `stat` output on Android: `<size> <path>` — toybox/busybox supports `-c '%s %n'`.
adb shell "find $PHONE_MUSIC_ROOT -type f -exec stat -c '%s	%n' {} + 2>/dev/null" > "$PHONE_FILES" || true
phone_inventory_secs=$(( $(date +%s) - phone_inventory_start ))
phone_count=$(wc -l < "$PHONE_FILES" | tr -d ' ')
echo "→ Phone inventory: $phone_count file(s) (${phone_inventory_secs}s)"

# 4b. Decide push-or-skip per track. Awk builds two indices over the phone
#     inventory: full-path (exact match) and (size, basename) (same-content match
#     under a different layout). For each track:
#       - If exact dest path exists → SKIP (use computed dest in M3U)
#       - Else if (size, basename) matches → SKIP, M3U points at the existing path
#       - Else → PUSH (stage + tar-stream)
#     Output columns:
#       src \t m3u_dest \t rel \t artist \t title \t duration \t status (SKIP|PUSH)
# Pre-compute file sizes in ONE batched stat call (the per-track loop version
# of this was 12s for 126 tracks because each iteration spawned a subprocess).
# `stat -f '%z\t%N' f1 f2 ...` handles many paths in a single invocation; `xargs
# -0 -n 200` chunks 200-at-a-time to stay under arg-length limits while keeping
# the number of subprocesses tiny.
#
# LC_ALL=C is necessary because BSD cut on macOS bails with "illegal byte
# sequence" on UTF-8 multi-byte chars (umlauts, accents) when the locale is
# UTF-8 and a track path contains them. Tab is single-byte, so byte-oriented
# cut Just Works.
MAC_SIZES="$TMP_DIR/mac_sizes.tsv"
LC_ALL=C cut -f1 "$TRACK_LIST" | LC_ALL=C tr '\n' '\0' | \
    xargs -0 -n 200 stat -f '%z	%N' 2>/dev/null > "$MAC_SIZES" || true

# Join sizes onto the track list. Awk reads sizes file into a hash keyed by path.
TRACK_LIST_SIZED="$TMP_DIR/tracks_with_size.tsv"
awk -F'\t' -v sizes_file="$MAC_SIZES" '
    BEGIN {
        while ((getline line < sizes_file) > 0) {
            tab = index(line, "\t")
            if (tab == 0) continue
            sizes[substr(line, tab + 1)] = substr(line, 1, tab - 1)
        }
        close(sizes_file)
    }
    { print $0 "\t" (sizes[$1] != "" ? sizes[$1] : "") }
' "$TRACK_LIST" > "$TRACK_LIST_SIZED"

DECISIONS="$TMP_DIR/decisions.tsv"
awk -F'\t' \
    -v phone_file="$PHONE_FILES" \
    -v music_root="$MAC_MUSIC_ROOT" \
    -v phone_root="$PHONE_MUSIC_ROOT" \
    '
    BEGIN {
        while ((getline line < phone_file) > 0) {
            # phone_file format: "<size>\t<path>"
            tab = index(line, "\t")
            if (tab == 0) continue
            size = substr(line, 1, tab - 1)
            path = substr(line, tab + 1)
            on_phone_path[path] = 1
            n = split(path, parts, "/"); base = parts[n]
            sizebase[size "|" base] = path
        }
        close(phone_file)
    }
    {
        # Input columns: src \t artist \t title \t duration \t size
        src = $1; artist = $2; title = $3; duration = $4; sz = $5
        if (music_root != "" && index(src, music_root "/") == 1) {
            rel = substr(src, length(music_root) + 2)
        } else {
            n = split(src, parts, "/"); rel = parts[n]
        }
        computed_dest = phone_root "/" rel
        status = "PUSH"
        m3u_dest = computed_dest
        if (computed_dest in on_phone_path) {
            status = "SKIP"
        } else {
            n2 = split(rel, rparts, "/"); basename = rparts[n2]
            if (sz != "" && (sz "|" basename) in sizebase) {
                status = "SKIP"
                m3u_dest = sizebase[sz "|" basename]
            }
        }
        print src "\t" m3u_dest "\t" rel "\t" artist "\t" title "\t" duration "\t" status
    }
    ' "$TRACK_LIST_SIZED" > "$DECISIONS"

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

# 4d. Bulk push via a single tar-stream over `adb shell`. Earlier attempts with
#     `adb push stage_dir/ /sdcard/Music/` had two problems: (1) it doesn't
#     dereference symlinks (it tries to create remote symlinks, which fails on
#     /sdcard's FUSE-emulated FS), and (2) `push localdir/ remotedir/` puts
#     localdir AS A SUBDIRECTORY of remotedir (`/sdcard/Music/stage/...`).
#
#     Tar handles both correctly: --dereference follows the symlinks at archive
#     time, and `tar -xf -` at the remote extracts in CWD, no path-mangling. One
#     adb session for the whole batch — replaces N per-file pushes that paid
#     ~50-200ms session overhead each.
if (( pushed > 0 )); then
    push_start=$(date +%s)
    ( cd "$STAGE_DIR" && tar -cf - --dereference . ) | \
        adb shell "cd '$PHONE_MUSIC_ROOT' && tar -xf -"
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
