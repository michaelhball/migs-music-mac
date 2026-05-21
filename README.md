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

## Setup

Everything you need on a fresh Mac.

### Install these

| What | How |
|---|---|
| **MigsMusicMac.app** | Download the latest `.dmg` from [Releases](https://github.com/michaelhball/migs-music-mac/releases/latest), open it, drag the app onto `Applications`. |
| **adb** | `brew install android-platform-tools` (or use the copy bundled with Android Studio). |
| **migs music** on your phone | Install the [Android app](https://github.com/michaelhball/migs-music). |
| **Apple Music** | The system app — already present on macOS 13+, nothing to install. |

### Grant these permissions

| Where | What to do | Why |
|---|---|---|
| Mac — first launch | Double-clicking the app will be blocked by Gatekeeper. Either **right-click → Open** → confirm, **or** open **System Settings → Privacy & Security**, scroll to the "migs music was blocked" notice, and click **Open Anyway**. One-time per Mac. | The app isn't notarised; Gatekeeper needs a one-time manual override. |
| Mac | **System Settings → Privacy & Security → Media & Apple Music** → turn on migs music | Lets the app read your Music library. macOS prompts for this on first launch — if you miss the prompt, enable it here. |
| Phone | **Settings → Developer options → USB debugging** → on | Lets `adb` talk to the phone. (Unlock Developer options by tapping *Build number* 7× under Settings → About phone.) |
| Phone | Plug in via USB, accept the **"Allow USB debugging?"** dialog | Authorises this specific Mac — tick "Always allow from this computer". |

It's working when `adb devices` lists your phone and the app's popover shows your playlists.

Updates are automatic after the first install — Sparkle checks once a day in the background; you can also click the version number in the popover footer to check on demand.

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
