# Troubleshooting

Common problems with the Mac sync app. If something here doesn't help, check `Console.app` (filter by `MigsMusicMac`) for errors.

## App doesn't appear in the menu bar

- **First launch needs Gatekeeper bypass.** macOS shows "*migs music* can't be opened because it is from an unidentified developer." Right-click the .app in Finder → **Open** → confirm in the dialog. Subsequent launches work normally.
- **Quit and relaunch.** macOS sometimes hides the menu bar item if too many other items compete for space. Quit migs music (the dropdown's Quit button) and `open /Applications/MigsMusicMac.app` again.
- **Bartender / Vanilla / similar menu bar managers** can hide the icon. Check their settings.

## "No device — plug in via USB"

- **Cable issue.** Some USB cables only carry power, not data. Try another cable. The phone needs to show as a "File transfer" target, not just charging.
- **USB debugging not enabled.** On the phone: Settings → About phone → tap *Build number* 7 times to unlock developer mode → Settings → System → Developer options → enable **USB debugging**.
- **Authorization not accepted.** First time you plug in to this Mac, the phone shows a "Allow USB debugging?" dialog. Accept (and tick "Always allow from this computer" so it doesn't re-prompt).
- The app auto-detects USB attach/detach via IOKit, so plugging in shows up in the popover within ~100ms — no manual refresh button. If the state seems stuck, quit the app from the dropdown and relaunch.

## "Unauthorised — accept the dialog on your phone"

ADB sees the phone but the trust prompt hasn't been accepted. Unlock the phone, look for the popup, tap **Allow**.

If the dialog never appeared:
```
adb kill-server
adb devices
```
Triggers a fresh authorisation request.

## "adb not found"

Install Android platform-tools:

```bash
brew install android-platform-tools
```

…or via the Android SDK Manager (Android Studio → SDK Tools → Android SDK Platform-Tools).

The app checks these paths in order: `~/Library/Android/sdk/platform-tools/adb`, `/usr/local/bin/adb`, `/opt/homebrew/bin/adb`, and the shell `PATH`.

## "Couldn't load playlists" or empty playlist list

- **Media & Apple Music permission denied.** macOS prompts on first launch with "*migs music* would like to access Apple Music data." Click **OK**.
- If you accidentally clicked Don't Allow: open **System Settings → Privacy & Security → Media & Apple Music**, toggle migs music on. The popover refreshes itself within ~200ms.
- **Music.app isn't installed.** The app reads via Apple's `iTunesLibrary` framework and only knows about Apple Music's library (no Spotify, no Tidal, no other source). On macOS 13+ Music.app is present by default.

## Auto-update isn't offering me a new release

The Mac app uses Sparkle for auto-updates and checks the GitHub-Pages-hosted `appcast.xml` once a day in the background. If the version label in the popover footer never says "Update available" despite a newer release being live:

- **Force a check:** click the version label in the popover footer. That triggers a synchronous `checkForUpdates()` and shows the result either way.
- **Network blocked.** Sparkle fetches `https://michaelhball.github.io/migs-music-mac/appcast.xml` over HTTPS. If your network blocks it, no update will ever appear. Try fetching that URL in a browser.
- **Update feed parse error.** A regression in `release.sh` could ship a malformed appcast. Check Console.app filtered to `Sparkle` for parse errors and open an issue.

## Sync says success but phone shows nothing

- **Check the phone's app first.** If migs music isn't running, OEM battery saver may have blocked the wake-up broadcast. Open the app once.
- **Verify the manifest pushed correctly:**
  ```
  adb shell "ls /sdcard/Android/media/com.migsmusic/sync/"
  ```
  If you see `.migs-sync-manifest`, the push worked. If not, the bash script's `adb push` failed silently — check the bash output in Console.
- **Check the phone-side logcat:**
  ```
  adb logcat -d | grep -E "AutoImport|MigsMusic"
  ```

## A sync fails — "Synced 0, N failed"

When a sync fails, the popover shows a short explanation of *what* went wrong and *how* to fix it, with the full sync log underneath for the details. The most common causes:

- **Music-library access not granted.** macOS hasn't given migs music permission to read your music. Click **Open Privacy Settings** in the failure box (or go to System Settings → Privacy & Security → Media & Apple Music), turn migs music on, then sync again.
- **Phone disconnected mid-sync.** The cable came loose or the phone locked itself. Reconnect, unlock, and retry.
- **A bundled helper was blocked by macOS.** On a fresh install macOS can quarantine the helper binary inside the app. The failure box prints the exact `xattr -dr com.apple.quarantine …` command to clear it.

**Why a sync could previously fail *entirely*:** earlier versions had a bug where a single playlist whose name contained a character the phone's storage can't use in a filename — `< > : " / \ | ? *`, e.g. a playlist called `<3` — made `adb push` fail, which aborted the whole run and marked *every* selected playlist as failed. This is fixed: such playlists now sync with each illegal character replaced by `_` (so `<3` appears on the phone as `_3`), and a single file that genuinely can't be copied no longer drags the rest down with it. If you hit a blanket failure, update to the latest release.

## Sync is slow / hangs

- **First sync of a large playlist** copies every audio file. Check `adb push` progress in the bash output. After that, re-syncing is effectively free (existing files are skipped).
- **Multi-GB playlists** can take a few minutes over USB. Don't disconnect mid-transfer.
- **adb stuck**: `adb kill-server && adb devices` resets it.

## The .dmg won't open / "damaged"

- **Gatekeeper for unsigned apps.** Right-click .dmg → Open. If macOS still refuses, in Terminal:
  ```
  xattr -d com.apple.quarantine ~/Downloads/migs-music-*.dmg
  ```
  Then double-click. The app inside may still need its own right-click → Open on first launch.
- **Corrupt download.** Verify the SHA256 against the `.sha256` next to the .dmg in the GitHub Release.

## I want to uninstall

```bash
# Quit the app first via the menu bar dropdown.
rm -rf /Applications/MigsMusicMac.app
defaults delete com.migsmusic.mac 2>/dev/null
rm -rf ~/Library/Caches/com.migsmusic.mac
```

The app doesn't write anywhere outside `~/Library/Preferences` and `~/Library/Caches` (LSUIElement apps don't get their own Application Support directory by default).
