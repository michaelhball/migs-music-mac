# Releasing migs music (Mac)

End-to-end process for cutting a new version, getting it onto GitHub Releases, and updating the Homebrew Cask.

## Prerequisites (one-time)

- `gh` CLI installed and authenticated (`gh auth login`).
- A separate `homebrew-migs` repo on your GitHub account (e.g. `michaelhball/homebrew-migs`). The repo just needs a `Casks/` directory; the formula in this repo's `Casks/migs-music.rb` is the source of truth and gets copied across each release.

That tap structure means users install with:
```
brew install --cask michaelhball/migs/migs-music
```

(`michaelhball` = your GitHub user, `migs` = the part after `homebrew-` in the tap repo name.)

## Each release

```bash
# 1. From this repo, on a clean main branch:
./release.sh 0.2.0 --tag

# This:
#   - bumps Info.plist CFBundleShortVersionString to 0.2.0
#   - bumps CFBundleVersion (build number)
#   - rebuilds release binary + .app bundle
#   - ad-hoc signs the .app
#   - produces dist/migs-music-0.2.0.dmg + .sha256
#   - commits the version bump + tags v0.2.0

# 2. Push the tag and the bump commit:
git push && git push --tags

# 3. Create the GitHub release with the .dmg attached:
gh release create v0.2.0 dist/migs-music-0.2.0.dmg \
  --title "v0.2.0" \
  --notes "What changed in this release."

# 4. Update Casks/migs-music.rb in THIS repo:
#    - version "0.2.0"
#    - sha256 "<value from dist/migs-music-0.2.0.dmg.sha256>"
#    Commit + push.

# 5. Copy the updated Cask to your homebrew-migs tap repo:
cp Casks/migs-music.rb ~/projects/homebrew-migs/Casks/migs-music.rb
cd ~/projects/homebrew-migs && git add Casks/migs-music.rb && \
    git commit -m "migs-music 0.2.0" && git push
```

Users on the tap will see the new version on their next `brew update`.

## Future automation

The 4-step flow above could collapse into a single command. Things to wire up later:

- A `gh release create` call inside `release.sh` itself (gated on `--publish` to avoid surprises).
- A small `bump-cask.sh` that reads `Casks/migs-music.rb`, swaps in the new version + sha256, and pushes a commit. Run automatically as part of `release.sh --publish`.
- Optionally a GitHub Action triggered by tag push that runs `release.sh`, creates the release, and updates the Cask in the tap repo. Keeps your laptop out of the loop entirely.

For now, the manual flow keeps you in the loop on each release, which is what you want until the app's stable enough to stop watching.

## Notarization (paid, deferred)

Without an Apple Developer account ($99/yr), the .dmg shows the standard Gatekeeper "unidentified developer" warning on first launch. Users right-click → Open the first time, then it runs cleanly. Acceptable for a free release.

To eliminate the warning entirely, sign up for an Apple Developer account, set up a Developer ID Application certificate, and add `notarytool` invocation to `release.sh` after the codesign step:

```bash
xcrun notarytool submit "$DMG_PATH" \
    --apple-id "you@example.com" \
    --team-id "ABCD1234EF" \
    --password "@keychain:notary-password" \
    --wait
xcrun stapler staple "$DMG_PATH"
```

Adds ~1–2 minutes per release for the notarization wait. Worth it once you're publishing to non-technical users.
