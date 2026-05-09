# Contributing to migs music (Mac)

Build internals, architecture, contribution notes.

## Prerequisites

- macOS 13+.
- Swift toolchain (Xcode Command Line Tools is enough — no full Xcode required).
- ADB on PATH or under one of: `~/Library/Android/sdk/platform-tools`, `/usr/local/bin`, `/opt/homebrew/bin`.

## Build

```bash
swift build                   # debug binary; for development
./build.sh                    # release binary + .app bundle in dist/
./release.sh 0.2.0            # full release: bump + build + DMG + appcast
./release.sh 0.2.0 --tag      # ditto, plus a v0.2.0 git tag
./release.sh 0.2.0 --publish  # ditto, plus push + GitHub Release upload
```

`build.sh` produces `dist/MigsMusicMac.app`. The bundle's `Info.plist` sets `LSUIElement = true` so the app stays out of the Dock. `build.sh` also copies `Sparkle.framework` (universal arm64+x86_64) from the resolved SwiftPM artifact into `Contents/Frameworks/`, ad-hoc signs the framework + main binary, and bundles the `sync-playlist-to-phone.sh` helper + `migs-tracks` CLI into `Contents/Resources/`.

`release.sh` wraps `build.sh` with versioning, DMG packaging (with Finder window styling), Sparkle EdDSA signing, and `appcast.xml` maintenance. See `RELEASING.md` for the full release workflow + Sparkle setup.

## Architecture

```
Sources/
├── MigsMusicMac/
│   ├── MigsMusicMacApp.swift   @main App + NSApplicationDelegateAdaptor (for Sparkle)
│   ├── UpdateState.swift       ObservableObject + SPUUpdaterDelegate; surfaces "update available"
│   ├── AppModel.swift          ObservableObject — device state, playlists, sync progress, lastSynced
│   ├── MusicAppService.swift   ITLibrary wrapper for "list user playlists"
│   ├── MusicLibraryWatcher.swift FSEvents watcher on ~/Music/Music/Music Library.musiclibrary
│   ├── USBDeviceMonitor.swift  IOKit-based attach/detach watcher; replaces polling
│   ├── ADBService.swift        adb path resolution + device state probe
│   ├── SyncOrchestrator.swift  Process wrapper for sync-playlist-to-phone.sh + manifest push
│   ├── ProcessRunner.swift     Generic Process wrapper with stdout/stderr capture
│   └── ContentView.swift       The menu-bar window UI (HeaderView/PlaylistListView/FooterView)
└── MigsTracks/
    └── main.swift              Tiny CLI; invoked by sync-playlist-to-phone.sh to dump a
                                playlist's track list via ITLibrary (replaces a per-sync
                                osascript, ~5x faster, scales to 10k+ track playlists).
```

### Live updates from Music.app

`MusicLibraryWatcher` watches `~/Music/Music/Music Library.musiclibrary/` via FSEvents (100ms coalesce window). `AppModel.scheduleLiveRefresh` debounces another 100ms on top, then re-queries ITLibrary. The popover playlist list updates within ~200ms of any Music.app edit (track imports, playlist renames, reorders, etc). The dominant remaining latency is Music.app's own flush delay before it persists changes to the bundle file — out of our hands.

### USB attach/detach detection

`USBDeviceMonitor` registers IOKit notifications for `kIOUSBDeviceClassName` matched/terminated events. On any USB plug/unplug, it calls `AppModel.refreshDevice()` so the device-state label updates within ~100ms. There's also a defensive 3–30s polling backoff loop in `ContentView.task` for edge cases where IOKit notifications miss.

### Sync flow

1. User ticks playlists in the menu-bar window, clicks Sync.
2. `SyncOrchestrator.pushManifest` writes `.migs-sync-manifest` (one playlist name per line, optional `#opts:deleteOrphans=true` first line) to `/sdcard/Android/media/com.migsmusic/sync/`. Pushed BEFORE the bash script runs so the deleteOrphans flag is available during each per-playlist replace.
3. `SyncOrchestrator.runSyncScript` runs `sync-playlist-to-phone.sh --no-broadcast` ONCE for all ticked playlists. The script does ONE phone inventory (find + stat over `/sdcard/Music`), shared file staging (symlinks), and ONE tar-stream push for all new audio. It also writes a `.migs-sync-stats` sidecar with the count of audio files actually pushed.
4. `SyncOrchestrator.broadcastAutoImport` fires-and-forgets the `AUTO_IMPORT` broadcast — does NOT await the on-device receiver. The data has already landed on the phone; awaiting `am broadcast` would add 5–10s for nothing.
5. On the phone, `AutoImportReceiver` reads the stats sidecar. If `audioPushed=0`, it skips the expensive MediaStore→Room rescan (saves ~3.9s on no-op resyncs). It then matches each .m3u via `M3uMatcherIndex` (absolutePath fast-path with lazy normalised maps), upserts playlists, applies the manifest-driven prune (whole-playlist removal for any synced playlist not in the manifest), deletes the manifest.

Why `/sdcard/Android/media/com.migsmusic/sync/` instead of the more obvious `/sdcard/Music/`: Android 11+ refuses to grant `ACTION_OPEN_DOCUMENT_TREE` access to media-collection subdirectories under `/sdcard/`. The picker shows "Can't use this folder" and there's no workaround. The app-specific external media directory needs no permission and works the same.

### Auto-update via Sparkle

`SPUStandardUpdaterController` lives on `MigsAppDelegate` (a class) rather than the App struct (a value type) so it survives scene rebuilds. The delegate is `UpdateState`, which exposes a `@Published availableVersion: String?` to drive the popover's "Update available" UX.

Sparkle reads its config from `Info.plist`:

- `SUFeedURL` — the appcast.xml on GitHub Pages, updated by `release.sh` on every release.
- `SUPublicEDKey` — the EdDSA public key. The matching private key lives in the macOS Keychain (`security find-generic-password -s 'https://sparkle-project.org' -a 'ed25519'`) with backups documented in `workspace/SPARKLE_BACKUPS.md`.
- `SUEnableAutomaticChecks` — true. Sparkle checks once a day in the background.

### Standalone bash script

`sync-playlist-to-phone.sh "<playlist name>"` runs the push directly and (without `--no-broadcast`) sends its own `AUTO_IMPORT` broadcast. Without a manifest, the receiver runs the per-file imports but skips the manifest-driven prune. Useful for one-off testing without affecting other synced playlists.

## Git layout

Separate repo from `migs-music` (the Android side). One git history per platform. Each repo has its own `release.sh` + GitHub Pages site.
