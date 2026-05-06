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
```

`build.sh` produces `dist/MigsMusicMac.app`. The bundle's `Info.plist` sets `LSUIElement = true` so the app stays out of the Dock. The bundled `sync-playlist-to-phone.sh` is copied into `Contents/Resources/`.

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
2. `SyncOrchestrator.syncMany` runs `sync-playlist-to-phone.sh` once per playlist.
3. Each script run pushes audio + `.m3u` over ADB and broadcasts `com.migsmusic.AUTO_IMPORT` (with `-f 0x20` so force-stopped phones still wake).
4. After all per-playlist syncs land, `pushManifestAndBroadcast` writes `.migs-sync-manifest` (one playlist name per line) to `/sdcard/Music/`, then re-broadcasts `AUTO_IMPORT`.
5. Phone-side receiver imports any pending `.m3u`, then reads the manifest and prunes any synced playlist not listed.
6. If `Delete audio files when unsynced` is on, the manifest's first line is `#opts:deleteOrphans=true`, signalling the phone to also delete orphan audio files.

### Standalone bash script

`sync-playlist-to-phone.sh "<playlist name>"` runs the per-playlist push without the manifest, so the phone-side mirror prune doesn't fire. Useful for one-off testing without affecting other synced playlists.

## Git layout

Separate repo from `migs-music` (the Android side). One git history per platform.
