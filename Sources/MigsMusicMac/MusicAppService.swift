import Foundation

/// One Music.app user playlist that the user can choose to sync.
struct MusicPlaylist: Identifiable, Hashable, Codable {
    /// Use the name as the id — Music.app's internal IDs aren't stable across launches in a
    /// way we can rely on, and AppleScript-friendly identification is the playlist name.
    /// Two playlists with the same name would collide; we let that surface as a UI bug to fix
    /// rather than silently merging them.
    var id: String { name }
    let name: String
    let trackCount: Int
}

enum MusicAppError: Error, LocalizedError {
    case scriptFailed(String)
    case notAuthorised

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let detail): return "Music.app script failed: \(detail)"
        case .notAuthorised: return "Not authorised to control Music.app. Grant access in System Settings → Privacy & Security → Automation."
        }
    }
}

/// Talks to the local Music.app via osascript. All Process.run calls are off the main actor.
enum MusicAppService {
    /// Lists every user playlist with its current track count, in Music.app's own order.
    /// Returns ([MusicPlaylist], nil) on success, or ([], error) on failure.
    static func listPlaylists() async -> Result<[MusicPlaylist], MusicAppError> {
        // TSV: "<count>\t<name>" per line. AppleScript's `name` can contain almost anything —
        // including tabs, in theory — but in practice playlist names are well-behaved. We
        // split on the FIRST tab so an embedded tab in a name would just become part of the
        // name field rather than corrupting parsing.
        //
        // Performance: previous version iterated `every user playlist` and read
        // `count of tracks of p` + `name of p` per iteration — that's 2 Music.app IPC calls
        // per playlist, ~5ms each = ~50ms per 50 playlists. Batched property reads
        // (`name of every user playlist`, `count of tracks of every user playlist`) collapse
        // to 2 calls total, regardless of playlist count.
        let script = #"""
        tell application "Music"
            set theNames to name of every user playlist
            set theCounts to count of tracks of every user playlist
            set out to ""
            set n to count of theNames
            repeat with i from 1 to n
                set out to out & ((item i of theCounts) as text) & tab & (item i of theNames) & linefeed
            end repeat
            return out
        end tell
        """#

        let result = await ProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script]
        )

        if !result.ok {
            let stderr = result.stderr
            if stderr.contains("Not authorised") || stderr.contains("Not authorized") || stderr.contains("-1743") {
                return .failure(.notAuthorised)
            }
            return .failure(.scriptFailed(stderr.isEmpty ? result.stdout : stderr))
        }

        let playlists = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> MusicPlaylist? in
                // Split on first tab; a stray tab in a name (rare) becomes part of name.
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                guard let count = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
                let trimmedName = parts[1].trimmingCharacters(in: .whitespaces)
                return trimmedName.isEmpty ? nil : MusicPlaylist(name: trimmedName, trackCount: count)
            }
        return .success(playlists)
    }
}
