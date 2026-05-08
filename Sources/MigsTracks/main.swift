// migs-tracks — print a playlist's tracks as TSV via iTunesLibrary.framework.
//
// Replaces the AppleScript track-dump in sync-playlist-to-phone.sh with a single
// fast binary-library read. Output format (one row per track with a local file):
//
//   <posix-path>\t<artist>\t<title>\t<duration-seconds>
//
// Tracks without a local file (Apple Music streaming-only) are silently skipped
// — same behavior as the AppleScript version.
//
// Usage:
//   migs-tracks "<playlist name>" [--out <path>]
//
// Exit codes:
//   0  success
//   1  argument error
//   2  ITLibrary load failed (no permission, library file missing, etc.)
//   3  no playlist with that name found

import Foundation
import iTunesLibrary

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: migs-tracks \"<playlist name>\" [--out <path>]\n".utf8))
    exit(1)
}
let playlistName = args[1]
var outPath: String? = nil
var i = 2
while i < args.count {
    if args[i] == "--out", i + 1 < args.count {
        outPath = args[i + 1]
        i += 2
    } else {
        FileHandle.standardError.write(Data("unknown arg: \(args[i])\n".utf8))
        exit(1)
    }
}

let library: ITLibrary
do {
    library = try ITLibrary(apiVersion: "1.0")
} catch {
    FileHandle.standardError.write(Data("ITLibrary failed: \(error.localizedDescription)\n".utf8))
    exit(2)
}

guard let playlist = library.allPlaylists.first(where: { $0.name == playlistName && !$0.isPrimary }) else {
    FileHandle.standardError.write(Data("no playlist named \"\(playlistName)\"\n".utf8))
    exit(3)
}

// Build the TSV in memory then write once. For ~1000-track playlists this is
// trivial; for 10k-track ones it's still under a few hundred KB.
var out = ""
for item in playlist.items {
    guard let url = item.location, url.isFileURL else { continue }
    let path = url.path
    let artist = item.artist?.name ?? ""
    let title = item.title
    // ITLibrary reports duration in seconds as Int (rounded). Music.app's
    // AppleScript path passed -1 for tracks where Music.app couldn't coerce
    // the duration; ITLibrary's `totalTime` is milliseconds, always present
    // for local files.
    let durationSec = item.totalTime / 1000
    // Sanitize embedded tabs/newlines in metadata fields; the bash side reads
    // the TSV with `IFS=$'\t' read -r src artist title duration` and would
    // mis-split rows that contain literal tabs.
    func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
    out += "\(path)\t\(clean(artist))\t\(clean(title))\t\(durationSec)\n"
}

if let outPath = outPath {
    do {
        try out.write(toFile: outPath, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error.localizedDescription)\n".utf8))
        exit(2)
    }
} else {
    FileHandle.standardOutput.write(Data(out.utf8))
}
