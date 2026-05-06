# Contributing to migs music (Mac)

Build internals, architecture, contribution notes.

## Prerequisites

- macOS 13+.
- Swift toolchain (Xcode Command Line Tools is enough — no full Xcode required).
- ADB on PATH or under one of: `~/Library/Android/sdk/platform-tools`, `/usr/local/bin`, `/opt/homebrew/bin`.

## Build

```bash
swift build              # debug binary; for development
./build.sh               # release binary + .app bundle in dist/
./release.sh             # rebuild + ad-hoc sign + .dmg packaging
./release.sh 0.2.0       # ditto, with explicit version bump
./release.sh 0.2.0 --tag # ditto, plus a v0.2.0 git tag
./release.sh 0.2.0 --publish  # ditto, plus push + GitHub Release + Cask bump
```

`build.sh` produces `dist/MigsMusicMac.app`. The bundle's `Info.plist` sets `LSUIElement = true` so the app stays out of the Dock. The bundled `sync-playlist-to-phone.sh` is copied into `Contents/Resources/`.

`release.sh` wraps `build.sh` with versioning, ad-hoc code signing, and `.dmg` packaging. See `RELEASING.md` for the full release workflow.

`bump-cask.sh <version>` updates `Casks/migs-music.rb` to point at the just-built release. Called by `release.sh --publish`; can also be run standalone if you're recovering from a half-completed release.

`.github/workflows/release.yml` runs the same chain on `git push --tags v*` so you don't have to babysit your laptop for a release.

## Architecture

```
Sources/MigsMusicMac/
├── MigsMusicMacApp.swift     @main App with MenuBarExtra(.window)
├── AppModel.swift            ObservableObject — device state, playlists, sync progress
├── MusicAppService.swift     osascript wrapper for "list user playlists"
├── ADBService.swift          adb path resolution + device state probe
├── SyncOrchestrator.swift    Process wrapper for sync-playlist-to-phone.sh + manifest push
└── ContentView.swift         The menu-bar window UI
```

### Sync flow

1. User ticks playlists in the menu-bar window, clicks Sync.
2. `SyncOrchestrator.pushManifest` writes `.migs-sync-manifest` (one playlist name per line, optional `#opts:` first line) to `/sdcard/Android/media/com.migsmusic/sync/`. Pushed BEFORE the per-playlist runs so the receiver sees the deleteOrphans flag during each replace.
3. `SyncOrchestrator.syncMany` runs `sync-playlist-to-phone.sh --no-broadcast` once per ticked playlist. Each run pushes audio files (to `/sdcard/Music/...`) + the `.m3u` (to `/sdcard/Android/media/com.migsmusic/sync/`) but doesn't broadcast.
4. `SyncOrchestrator.broadcastAutoImport` sends ONE `AUTO_IMPORT` broadcast at the end. The receiver does all imports + per-song orphan cleanup + whole-playlist prune in a single atomic pass, then deletes the manifest.
5. If `Delete audio files when unsynced` is on, the manifest's first line is `#opts:deleteOrphans=true`. Per-song orphan cleanup drops `SongEntity` rows from Room; actual file deletion is deferred to a future Settings screen on the phone (background `BroadcastReceiver` can't show the `MediaStore.createDeleteRequest` confirm dialog Android requires).

Why `/sdcard/Android/media/com.migsmusic/sync/` instead of the more obvious `/sdcard/Music/`: Android 11+ refuses to grant `ACTION_OPEN_DOCUMENT_TREE` access to media-collection subdirectories under `/sdcard/`. The picker shows "Can't use this folder" and there's no workaround. The app-specific external media directory needs no permission and works the same.

### Standalone bash script

`sync-playlist-to-phone.sh "<playlist name>"` runs the per-playlist push and broadcasts `AUTO_IMPORT` itself — the receiver runs without a manifest in that path, so per-song orphan cleanup + whole-playlist prune don't fire. Useful for one-off testing without affecting other synced playlists.

## Git layout

Separate repo from `migs-music` (the Android side). One git history per platform.
