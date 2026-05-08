import CoreServices
import Foundation

/// Fires `onChange` whenever Music.app writes to its library bundle on disk
/// (`~/Music/Music/Music Library.musiclibrary/`). Music.app persists edits
/// — adding a track to a playlist, renaming a playlist, reordering — with
/// a small debounce; FSEvents picks up the resulting writes and gives us a
/// reliable "library changed" signal that doesn't depend on the iTunesLibrary
/// framework's notification path (which seems unreliable on modern macOS).
///
/// We coalesce bursts of FSEvents into a single notification by passing a
/// `latency` to `FSEventStreamCreate` — it batches events that arrive within
/// the latency window. The receiver should also debounce on its own side.
final class MusicLibraryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let path = MusicLibraryWatcher.libraryBundlePath()
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: opaqueSelf,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, _, _, _ in
            guard let info = info, numEvents > 0 else { return }
            let watcher = Unmanaged<MusicLibraryWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onChange() }
        }

        let paths = [path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        // 0.1s coalesce window — Music.app's saves are bursty (several writes
        // for one logical edit). The receiver also debounces, so this is just
        // the FSEvents-layer pre-batch. Tighter than the default 0.25s because
        // the dominant latency is Music.app's own flush delay; we don't want
        // to add to it.
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else { return nil }
        self.stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    private static func libraryBundlePath() -> String {
        // Modern macOS: ~/Music/Music/Music Library.musiclibrary/
        // (The file inside is "Library.musicdb", but FSEvents on the bundle
        // dir catches every write reliably.)
        let home = NSHomeDirectory()
        return "\(home)/Music/Music/Music Library.musiclibrary"
    }
}
