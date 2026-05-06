import Foundation

/// One Music.app user playlist that the user can choose to sync.
struct MusicPlaylist: Identifiable, Hashable {
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
        let script = #"""
        tell application "Music"
            set out to ""
            repeat with p in (every user playlist)
                try
                    set out to out & ((count of tracks of p) as text) & tab & (name of p as text) & linefeed
                end try
            end repeat
            return out
        end tell
        """#
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", script]
                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe
                do {
                    try task.run()
                } catch {
                    continuation.resume(returning: .failure(.scriptFailed(error.localizedDescription)))
                    return
                }
                task.waitUntilExit()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                if task.terminationStatus != 0 {
                    if stderr.contains("Not authorised") || stderr.contains("Not authorized") || stderr.contains("-1743") {
                        continuation.resume(returning: .failure(.notAuthorised))
                    } else {
                        continuation.resume(returning: .failure(.scriptFailed(stderr.isEmpty ? stdout : stderr)))
                    }
                    return
                }

                let playlists = stdout
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .compactMap { line -> MusicPlaylist? in
                        // Split on first tab; a stray tab in a name (rare) becomes part of name.
                        guard let tabIndex = line.firstIndex(of: "\t") else { return nil }
                        let countString = String(line[..<tabIndex])
                        let name = String(line[line.index(after: tabIndex)...])
                        guard let count = Int(countString.trimmingCharacters(in: .whitespaces)) else { return nil }
                        let trimmedName = name.trimmingCharacters(in: .whitespaces)
                        return trimmedName.isEmpty ? nil : MusicPlaylist(name: trimmedName, trackCount: count)
                    }
                continuation.resume(returning: .success(playlists))
            }
        }
    }
}
