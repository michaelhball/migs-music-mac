# MIGS Music Mac

Mac-side companion to the [MIGS Music](../migs-music) Android player. Sits in your menu bar, lists your Apple Music playlists, and one-click-syncs any of them to your phone — copying only the audio files that aren't already there, generating a fresh `.m3u`, and dropping the lot into the phone's Music folder so the Android app can import it.

## Status

**Scripts work, menu bar app not yet built.** The two shell tools are battle-tested end-to-end (8/8 tracks synced + imported on a real device). The SwiftUI menu bar wrapper is the next piece — see *Plan* below.

## What's here today

- **`sync-playlist-to-phone.sh "<playlist name>"`** — pushes a Music.app playlist + every audio file it references to a USB-connected Android phone, dedups by destination path so re-syncing is effectively free for already-pushed audio, broadcasts a media-scanner request per file so Android picks up the ID3 tags immediately, and writes the M3U last so MIGS Music's auto-detect picks it up cleanly.

- **`export-playlist-as-m3u.applescript`** — standalone AppleScript that just exports a Music.app playlist to a `.m3u` file. Useful if you want to test the Android importer without copying audio.

### Prerequisites

- macOS with Apple Music.
- Phone connected via USB with ADB authorised (`adb devices` should show one device).
- First time you run `sync-playlist-to-phone.sh`, macOS will ask Terminal for permission to control Music.app — click *OK*.

### Usage

```bash
./sync-playlist-to-phone.sh "My Test Playlist"
```

The script reports per-file pushes, totals, and any tracks it couldn't transfer (streaming-only Apple Music tracks have no local file).

## Plan: menu bar app

When built, the app will:

1. Live in the macOS menu bar (no Dock icon).
2. On click, drop down a list of your Apple Music user playlists.
3. Each playlist row has a *Sync to phone* button.
4. Tap → shells out to `sync-playlist-to-phone.sh` with the playlist name; shows progress in the popover.
5. Reports completion with track counts (pushed / skipped / unmatched).

Architecture sketch:

```
Sources/MigsMusicMac/
├── MigsMusicMacApp.swift     # @main App with MenuBarExtra
├── AppModel.swift            # ObservableObject — playlists, status
├── MusicAppService.swift     # osascript wrapper for "list playlists"
├── SyncService.swift         # Process wrapper for sync-playlist-to-phone.sh
└── ContentView.swift         # The menu bar dropdown UI
```

Build approach (no Xcode required for users): a small `build.sh` that compiles the Swift sources with `swiftc`, assembles a proper `.app` bundle (with `Info.plist` setting `LSUIElement = true` so it stays out of the Dock), and copies the bash + AppleScript files into the bundle's `Resources/` so the running app can shell out to them via `Bundle.main.url(forResource:withExtension:)`.

## Git layout

This is a separate repo from `migs-music` (the Android app). Single git history per platform — Android-side commits don't clutter the Mac project, and vice versa. `device-smoke-test.sh` (the Android instrumentation runner) stays in the Android repo since it's specific to that side.
