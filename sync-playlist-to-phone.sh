#!/usr/bin/env bash
#
# sync-playlist-to-phone.sh — push one or more Music.app playlists + their audio
# files to a phone. Optimised for huge libraries: a single phone-inventory call,
# shared file-staging across playlists, and one tar-stream for the whole batch.
#
# Usage:
#   sync-playlist-to-phone.sh [--no-broadcast] "Playlist1" ["Playlist2" ...]
#
# What it does:
#   1. Reads each playlist's track list via the migs-tracks ITLibrary CLI helper
#      (or AppleScript fallback).
#   2. Inventories /sdcard/Music ONCE and dedups by (size, basename) so songs
#      already on the phone — even at a different path — aren't re-pushed.
#   3. Stages every missing track (across all playlists) into a single local
#      tree, then streams the whole tree to the phone via one `adb shell tar`.
#   4. Pushes one M3U per playlist into /sdcard/Android/media/com.migsmusic/sync/.
#   5. Broadcasts AUTO_IMPORT once at the end (unless --no-broadcast).

set -euo pipefail

# Optional millisecond-resolution profiling. Set MIGS_PROFILE=1 to print a
# "[+Nms phase]" line for every phase boundary. Uses gdate when available
# (Homebrew coreutils), falls back to python3. Cheap when off — one var read.
if [[ -n "${MIGS_PROFILE:-}" ]]; then
    if command -v gdate > /dev/null 2>&1; then
        _now_ms() { gdate +%s%3N; }
    else
        _now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
    fi
    _T_START=$(_now_ms)
    T() { echo "  [+$(( $(_now_ms) - _T_START ))ms] $*" >&2; }
else
    T() { :; }
fi
T "start"

BROADCAST_ON_DONE=true
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-broadcast) BROADCAST_ON_DONE=false ;;
        *) ARGS+=("$arg") ;;
    esac
done

if (( ${#ARGS[@]} == 0 )); then
    echo "Usage: $0 [--no-broadcast] \"<playlist>\" [\"<playlist>\" ...]" >&2
    exit 1
fi

# 1. Verify ADB device.
if ! adb get-state > /dev/null 2>&1; then
    echo "✗ No ADB device. Is the phone plugged in and authorised?" >&2
    exit 1
fi
T "adb get-state ok"

TMP_DIR=$(mktemp -d -t migs-sync-XXXX)
trap "rm -rf $TMP_DIR" EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 2. Locate migs-tracks (preferred) or fall back to AppleScript.
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

dump_playlist() {
    local name="$1" out="$2"
    if [[ -n "$MIGS_TRACKS" ]]; then
        "$MIGS_TRACKS" "$name" --out "$out" || true
    else
        osascript - "$name" "$out" <<'APPLESCRIPT'
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
}

# 3. Discover the Music.app media root for clean relative paths.
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
STAGE_DIR="$TMP_DIR/stage"
mkdir -p "$STAGE_DIR"

# 4. Kick off the phone inventory in the background — it's a single adb roundtrip
# but ~1–2s over USB for libraries with thousands of files. We `wait` on it just
# before the awk decision step, by which point migs-tracks (~200ms) has already
# run, so the inventory's wall-clock cost is hidden behind the playlist dump.
# The same adb-shell call also creates the sync dir, saving an extra roundtrip
# (mkdir -p is a no-op if it already exists).
PHONE_FILES="$TMP_DIR/phone_files.tsv"
(
    adb shell "mkdir -p '$PHONE_SYNC_DIR' && find $PHONE_MUSIC_ROOT -type f -exec stat -c '%s	%n' {} + 2>/dev/null" > "$PHONE_FILES" || true
) &
PHONE_INVENTORY_PID=$!
T "phone inventory started (bg pid=$PHONE_INVENTORY_PID)"

# Aggregate counters across all playlists.
TOTAL_PUSHED=0
TOTAL_SKIPPED=0
TOTAL_MISSING=0
M3U_PATHS=()

# When multiple playlists reference the same audio file, we want to stage it
# once. The staging tree itself is the dedup index — we check if the target
# symlink already exists before linking. Filesystem stat is O(1); the previous
# grep-based dedup was O(N*M) per playlist and would have blown up on huge
# libraries.

for PLAYLIST_NAME in "${ARGS[@]}"; do
    track_list="$TMP_DIR/${PLAYLIST_NAME}.tracks.tsv"
    dump_playlist "$PLAYLIST_NAME" "$track_list"
    T "dumped \"$PLAYLIST_NAME\""

    if [[ ! -s "$track_list" ]]; then
        echo "⚠ \"$PLAYLIST_NAME\": no playable tracks (empty or all streaming-only)." >&2
        continue
    fi
    track_count=$(wc -l < "$track_list" | tr -d ' ')
    echo "→ \"$PLAYLIST_NAME\": $track_count tracks with local files."

    # 4a. Pre-compute file sizes in ONE batched stat call. LC_ALL=C so BSD cut/tr
    # don't choke on UTF-8 multi-byte chars in track paths.
    mac_sizes="$TMP_DIR/${PLAYLIST_NAME}.sizes.tsv"
    LC_ALL=C cut -f1 "$track_list" | LC_ALL=C tr '\n' '\0' | \
        xargs -0 -n 200 stat -f '%z	%N' 2>/dev/null > "$mac_sizes" || true
    T "  mac stat ($(wc -l < "$track_list" | tr -d ' ') tracks)"

    # 4b. Join sizes onto the track list.
    sized="$TMP_DIR/${PLAYLIST_NAME}.sized.tsv"
    awk -F'\t' -v sizes_file="$mac_sizes" '
        BEGIN {
            while ((getline line < sizes_file) > 0) {
                tab = index(line, "\t"); if (tab == 0) continue
                sizes[substr(line, tab + 1)] = substr(line, 1, tab - 1)
            }
            close(sizes_file)
        }
        { print $0 "\t" (sizes[$1] != "" ? sizes[$1] : "") }
    ' "$track_list" > "$sized"

    # 4c. Awk decides PUSH/SKIP per track. Output: src \t m3u_dest \t rel \t artist \t title \t duration \t status
    # Join the background phone-inventory here — it's been running concurrently
    # with the playlist dumps and mac-side stat. `wait` is a no-op if it's done.
    if [[ -n "${PHONE_INVENTORY_PID:-}" ]]; then
        wait "$PHONE_INVENTORY_PID" || true
        unset PHONE_INVENTORY_PID
        phone_count=$(wc -l < "$PHONE_FILES" | tr -d ' ')
        echo "→ Phone inventory: $phone_count file(s)"
        T "phone inventory joined ($phone_count files)"
    fi
    decisions="$TMP_DIR/${PLAYLIST_NAME}.decisions.tsv"
    awk -F'\t' \
        -v phone_file="$PHONE_FILES" \
        -v music_root="$MAC_MUSIC_ROOT" \
        -v phone_root="$PHONE_MUSIC_ROOT" \
        '
        BEGIN {
            while ((getline line < phone_file) > 0) {
                tab = index(line, "\t"); if (tab == 0) continue
                size = substr(line, 1, tab - 1)
                path = substr(line, tab + 1)
                on_phone_path[path] = 1
                n = split(path, parts, "/"); base = parts[n]
                sizebase[size "|" base] = path
            }
            close(phone_file)
        }
        {
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
    ' "$sized" > "$decisions"

    # 4d. Build the M3U + stage missing files (deduped across playlists).
    m3u_out="$TMP_DIR/${PLAYLIST_NAME}.m3u"
    echo "#EXTM3U" > "$m3u_out"
    pl_pushed=0; pl_skipped=0; pl_missing=0
    while IFS=$'\t' read -r src m3u_dest rel artist title duration status; do
        if [[ ! -f "$src" ]]; then
            pl_missing=$((pl_missing + 1)); continue
        fi
        echo "#EXTINF:${duration:-0},$artist - $title" >> "$m3u_out"
        echo "$m3u_dest" >> "$m3u_out"
        case "$status" in
            SKIP) pl_skipped=$((pl_skipped + 1)) ;;
            PUSH)
                stage_target="$STAGE_DIR/$rel"
                if [[ ! -e "$stage_target" ]]; then
                    mkdir -p "$(dirname "$stage_target")"
                    ln -sf "$src" "$stage_target"
                    pl_pushed=$((pl_pushed + 1))
                fi
                ;;
        esac
    done < "$decisions"

    M3U_PATHS+=("$m3u_out")
    TOTAL_PUSHED=$((TOTAL_PUSHED + pl_pushed))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + pl_skipped))
    TOTAL_MISSING=$((TOTAL_MISSING + pl_missing))
    echo "  → push=$pl_pushed skip=$pl_skipped missing=$pl_missing"
    T "  decided + staged"
done

# 5. ONE tar-stream to the phone with every staged file from every playlist.
if (( TOTAL_PUSHED > 0 )); then
    push_start=$(date +%s)
    ( cd "$STAGE_DIR" && tar -cf - --dereference . ) | \
        adb shell "cd '$PHONE_MUSIC_ROOT' && tar -xf -"
    push_secs=$(( $(date +%s) - push_start ))
    echo "→ Pushed $TOTAL_PUSHED file(s) in ${push_secs}s"
    T "tar-stream push ($TOTAL_PUSHED files)"
fi

# 6. Push every M3U.
for m3u in "${M3U_PATHS[@]}"; do
    base=$(basename "$m3u")
    adb push "$m3u" "$PHONE_SYNC_DIR/$base" > /dev/null
done
T "pushed ${#M3U_PATHS[@]} m3u(s)"

# 6a. Sidecar with the audio-pushed count. Lets the phone-side import skip the
# expensive MediaStore→Room rescan on no-op resyncs (audioPushed=0). Anything
# the receiver doesn't recognise is ignored, so older Android builds just see
# an unfamiliar file and carry on.
stats_file="$TMP_DIR/.migs-sync-stats"
echo "audioPushed=$TOTAL_PUSHED" > "$stats_file"
adb push "$stats_file" "$PHONE_SYNC_DIR/.migs-sync-stats" > /dev/null
T "pushed sync-stats sidecar"

# 7. Trigger migs music's auto-import (once, after all M3Us land).
imported_on_phone=true
if [[ "$BROADCAST_ON_DONE" == true ]]; then
    adb shell "am broadcast -a com.migsmusic.AUTO_IMPORT -p com.migsmusic -f 0x20" > /dev/null 2>&1 || true
    T "broadcast"

    imported_on_phone=false
    # macOS ships bash 3.2 — no negative array indices. Compute the last index manually.
    last_idx=$(( ${#M3U_PATHS[@]} - 1 ))
    last_m3u_dest="$PHONE_SYNC_DIR/$(basename "${M3U_PATHS[$last_idx]}")"
    quoted_m3u=$(printf '%q' "$last_m3u_dest")
    for _ in $(seq 1 10); do
        if ! adb shell "[ -e $quoted_m3u ]" > /dev/null 2>&1; then
            imported_on_phone=true; break
        fi
        sleep 0.5
    done
    T "wait for import (imported=$imported_on_phone)"
fi
T "done"

echo ""
if [[ "$BROADCAST_ON_DONE" == false ]]; then
    echo "✓ Pushed (orchestrator will broadcast at end)."
elif [[ "$imported_on_phone" == true ]]; then
    echo "✓ Synced. Phone imported ${#M3U_PATHS[@]} playlist(s)."
else
    echo "⚠ Pushed, but phone hasn't auto-imported within 5s."
    echo "  Open migs music to trigger the import manually."
fi
echo "  Pushed audio files:           $TOTAL_PUSHED"
echo "  Already on phone (skipped):   $TOTAL_SKIPPED"
if (( TOTAL_MISSING > 0 )); then
    echo "  Missing local files:          $TOTAL_MISSING  (file moved or deleted on Mac)"
fi
