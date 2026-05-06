-- Exports a Music.app playlist to an Extended M3U file.
--
-- Usage:
--   1. In Music.app, make a note of the exact playlist name.
--   2. Run this script via Script Editor (Cmd+R) or via osascript:
--        osascript scripts/export-playlist-as-m3u.applescript
--   3. Enter the playlist name when prompted; pick a save location.
--
-- The .m3u will list each track as #EXTINF + the file's POSIX path.
-- Streaming-only Apple Music tracks (no local file) are skipped silently —
-- those won't be importable on the phone anyway because the audio isn't
-- on disk to copy across.

on run
    tell application "Music"
        activate
        set playlistName to text returned of (display dialog "Playlist to export:" default answer "" with title "Export to M3U")
        try
            set thePlaylist to user playlist playlistName
        on error
            display alert "Playlist not found" message "No playlist named “" & playlistName & "”." as critical
            return
        end try

        set saveTarget to choose file name with prompt "Save as .m3u" default name (playlistName & ".m3u")
        set saveFile to open for access saveTarget with write permission
        set eof of saveFile to 0
        write "#EXTM3U" & linefeed to saveFile

        set exportedCount to 0
        set skippedCount to 0
        repeat with t in (every track of thePlaylist)
            try
                set fileLocation to (POSIX path of (location of t as alias))
                set durationSec to (round (duration of t))
                set artistName to (artist of t) as string
                set trackName to (name of t) as string
                write "#EXTINF:" & durationSec & "," & artistName & " - " & trackName & linefeed to saveFile
                write fileLocation & linefeed to saveFile
                set exportedCount to exportedCount + 1
            on error
                set skippedCount to skippedCount + 1
            end try
        end repeat

        close access saveFile

        display alert ("Exported " & exportedCount & " tracks") message ("Skipped " & skippedCount & " streaming-only or missing tracks.")
    end tell
end run
