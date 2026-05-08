import CryptoKit
import Foundation
import iTunesLibrary

/// One Music.app user playlist that the user can choose to sync.
struct MusicPlaylist: Identifiable, Hashable, Codable {
    /// Use the name as the id — Music.app's internal IDs aren't stable across launches in a
    /// way we can rely on, and AppleScript-friendly identification is the playlist name.
    /// Two playlists with the same name would collide; we let that surface as a UI bug to fix
    /// rather than silently merging them.
    var id: String { name }
    let name: String
    let trackCount: Int
    /// Short hex digest of the playlist's ordered track-id list. Used by the sync-status
    /// indicator to detect "this playlist's contents have changed since the last successful
    /// sync to the phone". Order-sensitive: re-ordering a playlist also flips the hash.
    let contentHash: String
}

enum MusicAppError: Error, LocalizedError {
    case scriptFailed(String)
    case notAuthorised

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let detail): return "Music.app library read failed: \(detail)"
        case .notAuthorised: return "Not authorised to read Music.app's library. Grant access in System Settings → Privacy & Security → Media & Apple Music."
        }
    }
}

/// Reads Music.app's library directly via iTunesLibrary.framework. Orders of magnitude
/// faster than the previous AppleScript path because there's no `osascript` subprocess
/// and no AppleEvent IPC — ITLibrary just memory-maps the on-disk library binary.
///
/// Keeps the same `MusicPlaylist` shape and "every user playlist" filter semantics as
/// the AppleScript implementation it replaces, so callers don't notice the swap.
enum MusicAppService {
    /// Lists every user-created playlist with its current track count, in the order
    /// ITLibrary returns them (matches Music.app sidebar order in practice).
    static func listPlaylists() async -> Result<[MusicPlaylist], MusicAppError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let library: ITLibrary
                do {
                    library = try ITLibrary(apiVersion: "1.0")
                } catch {
                    let nsError = error as NSError
                    // ITLibrary throws an authorisation error (NSCocoaErrorDomain code 257)
                    // when the user has denied "Media & Apple Music" access in System
                    // Settings → Privacy & Security. Surface that as a distinct error so
                    // the UI can suggest the fix instead of showing a generic failure.
                    if nsError.localizedDescription.localizedCaseInsensitiveContains("permission")
                        || nsError.localizedDescription.localizedCaseInsensitiveContains("authoriz")
                        || nsError.localizedDescription.localizedCaseInsensitiveContains("authoris")
                    {
                        continuation.resume(returning: .failure(.notAuthorised))
                    } else {
                        continuation.resume(returning: .failure(.scriptFailed(error.localizedDescription)))
                    }
                    return
                }

                // Match the AppleScript's "every user playlist" semantics: user-created
                // playlists (regular + smart), exclude the master library ("Library",
                // isPrimary=true), exclude Music.app's distinguished system rows
                // (Music, Music Videos, TV Shows, Audiobooks, etc.), and exclude
                // folder rows. The previous AppleScript path was actually over-inclusive
                // here — it returned "Music" (the smart filter) as a syncable playlist.
                let userPlaylists = library.allPlaylists.filter { p in
                    !p.isPrimary &&
                        p.distinguishedKind == .kindNone &&
                        p.kind != .folder
                }
                let result = userPlaylists.map { p in
                    MusicPlaylist(
                        name: p.name,
                        trackCount: p.items.count,
                        contentHash: contentHash(for: p)
                    )
                }
                continuation.resume(returning: .success(result))
            }
        }
    }
}

/// Order-sensitive content hash of a playlist's track list. We use ITLibrary's
/// per-track persistentID (a UInt64 stable across launches) rather than file paths
/// or names — fast, exact, and not perturbed by tag rewrites or location changes.
/// Truncated to 16 hex chars (8 bytes of SHA-256) — collision risk for "did the
/// playlist contents change" is negligible at this length.
private func contentHash(for playlist: ITLibPlaylist) -> String {
    var hasher = SHA256()
    for item in playlist.items {
        var le = item.persistentID.uint64Value.littleEndian
        withUnsafeBytes(of: &le) { hasher.update(bufferPointer: $0) }
    }
    let digest = hasher.finalize()
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}
