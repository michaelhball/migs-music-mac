import Foundation

/// A plain-language interpretation of a *failed* sync, derived by pattern-matching
/// the sync script's combined output. Lets the popover say "here's what went wrong
/// and here's how to fix it" instead of dumping a raw shell log on the user.
struct SyncDiagnosis {
    /// One-line headline, e.g. "migs music can't read your Music library".
    let title: String
    /// A sentence or two of plain-language guidance on how to fix it.
    let suggestion: String
    /// When set, the popover offers a button that jumps straight to this
    /// System Settings pane.
    let settingsURL: URL?

    /// Deep link to System Settings → Privacy & Security → Media & Apple Music.
    private static let mediaPrivacyPane =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")

    /// Classify a failed sync's combined output. Returns `nil` when the output
    /// doesn't match any known failure mode — the caller then falls back to
    /// showing the raw log.
    ///
    /// Order matters: the most specific signals are checked first, because the
    /// sync script's "nothing synced" summary always also mentions "Media &
    /// Apple Music", so a more precise cause (e.g. a Gatekeeper-blocked helper)
    /// has to win before the generic permission branch.
    static func classify(_ output: String) -> SyncDiagnosis? {
        let text = output.lowercased()
        guard !text.isEmpty else { return nil }

        // The app bundle is missing the sync script — a broken/partial install.
        if text.contains("could not find sync-playlist-to-phone.sh") {
            return SyncDiagnosis(
                title: "migs music is missing a component",
                suggestion: "The bundled sync script wasn't found inside the app. "
                    + "Reinstall migs music from a fresh download.",
                settingsURL: nil
            )
        }

        // Phone not connected, or USB debugging not authorised.
        if text.contains("no adb device") {
            return SyncDiagnosis(
                title: "Phone not detected",
                suggestion: "Connect the phone over USB, unlock it, and accept the "
                    + "“Allow USB debugging” prompt — then sync again.",
                settingsURL: nil
            )
        }

        // The bundled migs-tracks helper couldn't be executed. On a fresh
        // download macOS quarantines nested helper binaries, and Gatekeeper
        // then blocks them the first time the sync script tries to run one.
        if text.contains("gatekeeper")
            || text.contains("cannot be opened because")
            || text.contains("developer cannot be verified") {
            return SyncDiagnosis(
                title: "macOS blocked part of migs music",
                suggestion: "macOS quarantined a helper bundled inside the app. "
                    + "Open Terminal and run:\n\n"
                    + "xattr -dr com.apple.quarantine \"/Applications/MigsMusicMac.app\"\n\n"
                    + "Then reopen migs music and sync again.",
                settingsURL: nil
            )
        }

        // A file transfer to the phone was refused mid-sync.
        if text.contains("could not copy playlist file")
            || text.contains("operation not permitted")
            || text.contains("no space left") {
            return SyncDiagnosis(
                title: "A file couldn’t be copied to the phone",
                suggestion: "The phone refused a file transfer. Make sure it’s "
                    + "unlocked and has free storage space, then sync again — if it "
                    + "keeps happening, reconnect the USB cable.",
                settingsURL: nil
            )
        }

        // Music-library access denied (TCC) — the most common first-run issue.
        if text.contains("media & apple music")
            || text.contains("music-library access")
            || text.contains("not authoris") || text.contains("not authoriz")
            || (text.contains("itlibrary")
                && (text.contains("permission") || text.contains("denied")
                    || text.contains("authoriz"))) {
            return SyncDiagnosis(
                title: "migs music can't read your Music library",
                suggestion: "macOS hasn't granted migs music access to your music. "
                    + "Open System Settings → Privacy & Security → Media & Apple Music, "
                    + "turn on migs music, then sync again.",
                settingsURL: mediaPrivacyPane
            )
        }

        // Catch-all for "nothing synced" with no more specific signal.
        if text.contains("nothing synced") || text.contains("no playable tracks") {
            return SyncDiagnosis(
                title: "No tracks could be read from the selected playlists",
                suggestion: "Nothing was read from Music. This is usually a "
                    + "library-access problem — check System Settings → Privacy & "
                    + "Security → Media & Apple Music — or the playlists may be empty.",
                settingsURL: mediaPrivacyPane
            )
        }

        return nil
    }
}
