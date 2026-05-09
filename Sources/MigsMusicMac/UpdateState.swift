import Combine
import Sparkle

/// Bridges Sparkle's delegate callbacks into a `@Published` flag the popover footer
/// observes. Sparkle's default UI handles all the prompts — what we need from it is
/// just a "yes there's an update" signal so we can surface it in our own UI without
/// the user having to click "Check for Updates" first.
///
/// Also acts as the SPUUpdaterDelegate so we can opt into a few extras down the line
/// (e.g. release-notes injection, custom feed URL per channel) without scattering
/// delegate plumbing around.
final class UpdateState: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// Non-nil when Sparkle has confirmed there's a newer version on the feed. The
    /// string is the human-readable "0.1.1" version. Cleared when the running version
    /// catches up (e.g. immediately after a successful install + relaunch).
    @Published var availableVersion: String?

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        // Sparkle reports the appcast item's `displayVersionString` (the human-readable
        // "shortVersionString") in its label; we use the same so the popover and Sparkle's
        // own dialog never disagree.
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_: SPUUpdater) {
        availableVersion = nil
    }
}
