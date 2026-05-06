# migs music (Mac)

Menu-bar app that syncs Apple Music playlists to the [migs music](../migs-music) Android player over USB.

Status: in active development. Build from source for now.

## What it does

- Lists your Music.app user playlists in the menu bar.
- Tick playlists → click Sync → audio files + `.m3u` land on the phone, in `Artist/Album/Track` structure.
- Already-on-phone tracks are skipped; re-syncing is effectively free.
- Mirror semantics: only ticked playlists exist on the phone after a sync. Untick → next sync removes from phone.
- Optional "delete audio files when unsynced" checkbox: also removes audio for songs no other playlist references. Default off.
- Auto-polls phone connection state while the menu is open.

## Prerequisites

- macOS 13+ with Apple Music.
- ADB installed (`brew install android-platform-tools` or via Android Studio).
- Phone with USB debugging on, plugged in, authorised (`adb devices`).
- migs music Android app installed on the phone.

## Installing

```bash
./build.sh                                  # produces dist/MigsMusicMac.app
cp -R dist/MigsMusicMac.app /Applications/
open /Applications/MigsMusicMac.app
```

First launch prompts to allow controlling Music.app — accept.

## Usage

1. Plug phone in.
2. Click menu-bar icon. Tick playlists.
3. Click Sync.

## Developer docs

[CONTRIBUTING.md](CONTRIBUTING.md) — build internals, architecture, bundled bash script, contribution notes.
