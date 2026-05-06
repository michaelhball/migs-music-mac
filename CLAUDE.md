# Claude Code config — migs-music-mac

## Workflow

**Commit + push tested work freely. One logical change per commit. Don't ask first.**

After every tested logical change:

1. Test what you changed. For shell scripts, run them end-to-end. For Swift code, `swift build` (when the menu bar app exists).
2. Stage just the files belonging to that one logical change.
3. `git commit` with a clear message that explains the *why*.
4. `git push origin main`.

**Don't bundle.** A bash fix + a Swift change + a README update should be three commits, not one.

**Push is the natural conclusion of "tested and works locally"** — not a step that needs a separate prompt from the user. The user has explicitly authorised direct push to `main`.

**Hold off only when**:

- Code is genuinely experimental / not yet tested.
- The change is destructive (force-push, branch deletion, history rewrite).
- The user has flagged the work as draft.

If something fails after a push, patch with a follow-up commit. Don't amend or force-push.

## Project layout

- `sync-playlist-to-phone.sh` — the working sync script. Pushes a Music.app playlist + missing audio files to a USB-connected Android phone via ADB.
- `export-playlist-as-m3u.applescript` — standalone AppleScript for M3U-only exports.
- `Sources/MigsMusicMac/` — (planned) SwiftUI menu bar app sources.
- `build.sh` — (planned) compiles + bundles the .app via `swiftc` so users don't need Xcode.

## Sibling repo

The Android phone app lives in [`~/projects/migs-music`](../migs-music), separate git repo. Same workflow rules apply there.
