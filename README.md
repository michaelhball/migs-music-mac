# migs music (Mac)

Menu-bar app that syncs Apple Music playlists to the [migs music](../migs-music) Android player over USB. macOS 13+, no Apple Developer account required.

## What it does

- Lists your Music.app user playlists in the menu bar.
- Tick the playlists you want on your phone → click Sync → audio files + `.m3u` land on the phone in `Artist/Album/Track` structure.
- Already-on-phone tracks are skipped; re-syncing a playlist with one new song takes about 2 seconds.
- Live updates: the playlist list refreshes within ~200ms when you edit anything in Music.app — no manual reload button.
- Per-playlist sync indicators show whether each playlist is in sync with the phone (green) or has changed since the last sync (orange).
- Mirror semantics: only ticked playlists exist on the phone after a sync. Untick → next sync removes from phone.
- Optional "delete audio files when unsynced": also removes audio for songs that no other playlist references. Default off.
- Auto-detects when a phone is plugged in or unplugged — no Refresh button.
- Auto-updates via Sparkle once the first install is in place.

## Installing

Download the latest `.dmg` from [the Releases page](https://github.com/michaelhball/migs-music-mac/releases/latest), open it, drag `MigsMusicMac.app` onto the `Applications` shortcut.

First launch:

1. Right-click the app in Applications and choose **Open** (the app isn't notarised, so the first launch needs this manual override; Gatekeeper remembers it after).
2. macOS will ask to allow controlling Music.app — accept.
3. Click the menu-bar music-note icon to open the popover.

After that, every later release updates itself: Sparkle checks once a day in the background. You can also click the version number in the popover footer to check on demand.

## Prerequisites

- macOS 13+ with Apple Music (the system app, free).
- `adb` installed: `brew install android-platform-tools`, or it ships with Android Studio.
- Android phone with USB debugging on, plugged in, authorised (`adb devices` should list it).
- The [migs music Android app](https://github.com/michaelhball/migs-music) installed on the phone.

## Usage

1. Plug your phone in.
2. Click the menu-bar music-note icon.
3. Tick the playlists you want on your phone.
4. Click **Sync**.

The orange dot next to a playlist means "differs from the last successful sync." Green means "matches what's on the phone."

## Privacy

[Privacy policy](https://michaelhball.github.io/migs-music/privacy.html) — short version: no telemetry, no analytics, no cloud sync. Your library never leaves your machines. The only network call is the Sparkle update check.

## Troubleshooting

[TROUBLESHOOTING.md](TROUBLESHOOTING.md) — common problems and fixes.

## Developer docs

[CONTRIBUTING.md](CONTRIBUTING.md) — build internals, architecture, bundled bash script, contribution notes.
[RELEASING.md](RELEASING.md) — version bumps, signing, GitHub Releases + Sparkle appcast flow.
