# Releasing migs music (Mac)

End-to-end process for cutting a new version: build, sign, package, push to GitHub Releases, update the appcast Sparkle reads.

Distribution is **DMG-only via GitHub Releases**. No Homebrew Cask. Users either download the DMG directly from the Releases page, or — once they've installed once — get auto-updates via Sparkle from the appcast.xml hosted on GitHub Pages.

## Prerequisites (one-time)

- `gh` CLI installed and authenticated (`gh auth login`).
- Sparkle EdDSA private key available — Sparkle's `generate_keys` stores it in the macOS Keychain by default. If this is a fresh laptop, restore from `workspace/SPARKLE_BACKUPS.md`.
- GitHub Pages enabled for this repo, serving from `/` on `main`. The `appcast.xml` at the repo root becomes `https://michaelhball.github.io/migs-music-mac/appcast.xml`, which is what `Info.plist`'s `SUFeedURL` points at.

## Each release

```bash
# From a clean main branch:
./release.sh 0.2.0 --publish

# This:
#   - bumps Info.plist CFBundleShortVersionString → 0.2.0
#   - bumps CFBundleVersion (build counter)
#   - rebuilds the .app via build.sh (bundles Sparkle.framework, ad-hoc signs)
#   - packages dist/migs-music-0.2.0.dmg with a styled Finder window
#   - signs the DMG with the Sparkle EdDSA key and prepends an <item> to appcast.xml
#   - commits the version bump + appcast update, tags v0.2.0
#   - pushes branch + tag
#   - creates the GitHub release and uploads the DMG as an asset
```

Without `--publish` (or with just `--tag`), `release.sh` stops short of pushing — useful for a dry run.

After the release lands, GitHub Pages re-serves the appcast within a couple of minutes. Existing installs of the running app see the new version on their next daily Sparkle check, or the user can click the version label in the popover to force a check immediately.

## Notarization (paid, deferred)

Without an Apple Developer ID ($99/yr), first-launch users see a Gatekeeper "unidentified developer" warning that they bypass with right-click → Open. For Sparkle's auto-update path the bundle is swapped in-place and Gatekeeper generally doesn't re-prompt — but **this needs validation on a fresh non-dev Mac before we trust it**.

To notarize once we have an account, add this between `codesign` and `hdiutil convert` in `release.sh`:

```bash
xcrun notarytool submit "$DMG_PATH" \
    --apple-id "you@example.com" \
    --team-id "ABCD1234EF" \
    --password "@keychain:notary-password" \
    --wait
xcrun stapler staple "$DMG_PATH"
```

Adds ~1–2 minutes per release for the notarization wait.
