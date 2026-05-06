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
- Click the menu bar's refresh button after plugging in. The app polls every 3s while the menu is open, but a manual click is faster.

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

## "Couldn't load playlists" with an osascript error

- **First run prompts for AppleEvents permission.** macOS shows "*migs music* would like to control Music." Click **OK**.
- If you accidentally clicked Don't Allow: go to **System Settings → Privacy & Security → Automation → migs music → Music** and toggle on. Then click Refresh in the menu bar app.
- **Music.app isn't installed.** The app uses Music.app exclusively (no Spotify, no Tidal, no other source). On macOS 13+ it should be present by default.

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
