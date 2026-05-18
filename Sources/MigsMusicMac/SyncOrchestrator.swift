import Foundation

/// Per-playlist sync result. The orchestrator collects these and the UI renders a summary.
struct SyncResult: Identifiable {
    let id = UUID()
    let playlistName: String
    let success: Bool
    /// Combined stdout+stderr from the bash script. Useful for debugging; not surfaced
    /// prominently in the UI unless something failed.
    let output: String
}

enum SyncOrchestrator {
    /// Runs `sync-playlist-to-phone.sh` once per playlist in [playlistNames], serially. The
    /// bash script is bundled inside the .app's Resources/ directory by build.sh — we look
    /// it up via Bundle.main and invoke /bin/bash with its absolute path.
    ///
    /// `progress` fires with each playlist's name when it starts (so the UI can show "syncing
    /// X of N: …"). The full result list is returned at the end.
    @discardableResult
    static func syncMany(
        playlistNames: [String],
        deleteOrphanedAudio: Bool = false,
        progress: @MainActor @escaping (_ index: Int, _ total: Int, _ name: String) -> Void
    ) async -> [SyncResult] {
        guard let scriptURL = bundledScriptURL() else {
            return playlistNames.map {
                SyncResult(
                    playlistName: $0,
                    success: false,
                    output: "Could not find sync-playlist-to-phone.sh inside the app bundle. Was it built with build.sh?"
                )
            }
        }

        // Push the manifest BEFORE running the sync so the deleteOrphans flag is
        // available to the receiver during each per-playlist replace (per-song orphan
        // cleanup). Pushing it after-the-fact would only catch whole-playlist removals.
        await pushManifest(playlistNames: playlistNames, deleteOrphanedAudio: deleteOrphanedAudio)

        // Single bash invocation handles every playlist in one pass: ONE phone
        // inventory, shared local staging tree, ONE tar-stream push for all new
        // audio. Previous version called the script N times, paying N×phone-inventory
        // and N×tar-push overhead — a meaningful drag for users with 50+ playlists.
        await MainActor.run { progress(0, playlistNames.count, playlistNames.first ?? "") }
        let result = await runSyncScript(
            scriptURL: scriptURL,
            playlistNames: playlistNames,
            noBroadcast: true
        )

        // Single AUTO_IMPORT broadcast after all syncs land. Receiver reads manifest,
        // imports any pending m3u files (with per-song orphan cleanup), prunes whole
        // playlists not in the manifest, deletes the manifest. One atomic pass.
        //
        // Fire-and-forget: `am broadcast` blocks until the on-device receiver returns,
        // and the receiver's import work for a 100+ track playlist takes 5–10s. Awaiting
        // it added that delay to the user's perceived "Syncing…" time for no benefit —
        // the data has already landed on the phone by this point. The phone catches up
        // in the background; if the user reopens the popover after a moment it'll show
        // the synced state. (Manifest + m3u files were pushed synchronously above, so
        // there's no race where the broadcast fires before the data is in place.)
        broadcastAutoImport()

        // Surface a per-playlist result for the UI's "Synced N / failed M" summary.
        // The bash script reports aggregate counts; we don't track per-playlist
        // success granularly anymore (a single failure on one playlist would still
        // produce stage entries for the others). If the bash script exits non-zero
        // we mark all playlists as failed; otherwise all succeed.
        return playlistNames.map { name in
            SyncResult(
                playlistName: name,
                success: result.success,
                output: result.output
            )
        }
    }

    private static func pushManifest(
        playlistNames: [String],
        deleteOrphanedAudio: Bool
    ) async {
        guard let adb = ADBService.adbPath() else { return }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("migs-sync-manifest-\(UUID().uuidString).txt")
        // Manifest format: optional first-line `#opts:k=v,k=v` for flags, then one playlist
        // name per line. Strip any embedded newlines / carriage returns from playlist names
        // — Music.app theoretically allows them but they'd corrupt the line-per-name format.
        // Replace filesystem-illegal characters via phoneSafeName so each manifest entry
        // matches the .m3u filename the bash script pushes for that playlist (the phone
        // prunes any playlist whose name isn't in the manifest, so they MUST agree).
        // Also drop any name starting with `#` so it can't be mistaken for an opts line.
        let sanitized = playlistNames
            .map { $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
            .map { phoneSafeName($0) }
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
        var lines: [String] = []
        if deleteOrphanedAudio {
            lines.append("#opts:deleteOrphans=true")
        }
        lines.append(contentsOf: sanitized)
        let body = lines.joined(separator: "\n") + "\n"
        do {
            try body.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Ensure the sync dir exists before pushing the manifest. mkdir -p is a no-op if
        // it already does. /sdcard/Android/media/<pkg>/ is created lazily by Android the
        // first time anyone writes there; we don't depend on the app having run before.
        _ = await ProcessRunner.run(
            executable: adb,
            arguments: ["shell", "mkdir -p /sdcard/Android/media/com.migsmusic/sync"]
        )
        _ = await ProcessRunner.run(
            executable: adb,
            arguments: ["push", tempURL.path, "/sdcard/Android/media/com.migsmusic/sync/.migs-sync-manifest"]
        )
    }

    /// Replaces characters that Android's FAT-derived `/sdcard` storage rejects in
    /// filenames (`< > : " / \ | ? *`) with `_`. Playlist names reach the phone as
    /// `.m3u` filenames, and `adb push` fails outright with "Operation not
    /// permitted" on any of them — a single offending name (e.g. "<3") previously
    /// aborted the entire sync. The bash script's `sanitize_for_phone` applies the
    /// identical rule when naming the m3u files; manifest entries built here must
    /// match those filenames, because the phone prunes any playlist whose name
    /// isn't listed in the manifest.
    private static func phoneSafeName(_ name: String) -> String {
        let illegal: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
        return String(name.map { illegal.contains($0) ? "_" : $0 })
    }

    private static func broadcastAutoImport() {
        guard let adb = ADBService.adbPath() else { return }
        // -f 0x20 = FLAG_INCLUDE_STOPPED_PACKAGES, same as the bash script. Without it the
        // broadcast is silently dropped if the app's been force-stopped.
        // Detached so we don't block on `am broadcast`'s wait-for-receiver behaviour —
        // see the call site for why.
        Task.detached {
            _ = await ProcessRunner.run(
                executable: adb,
                arguments: ["shell", "am broadcast -a com.migsmusic.AUTO_IMPORT -p com.migsmusic -f 0x20"]
            )
        }
    }

    /// Looks up the bundled bash script. build.sh copies it under Contents/Resources/ as
    /// `sync-playlist-to-phone.sh`. Bundle.main.url(forResource:withExtension:) handles the
    /// usual ./.app/Contents/Resources/ probe automatically.
    private static func bundledScriptURL() -> URL? {
        Bundle.main.url(forResource: "sync-playlist-to-phone", withExtension: "sh")
    }

    private static func runSyncScript(
        scriptURL: URL,
        playlistNames: [String],
        noBroadcast: Bool = false
    ) async -> SyncResult {
        var args = [scriptURL.path]
        if noBroadcast { args.append("--no-broadcast") }
        args.append(contentsOf: playlistNames)

        // Inherit a sane PATH so `adb` / `osascript` resolve the same way they would
        // from a Terminal session. The bash script also has explicit candidate paths
        // for adb internally, but giving it PATH access first keeps things tidy.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] =
            [
                env["PATH"] ?? "",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "\(NSHomeDirectory())/Library/Android/sdk/platform-tools",
            ]
            .filter { !$0.isEmpty }
            .joined(separator: ":")

        // Merge stdout + stderr — the bash script interleaves progress with errors and
        // we want chronological output for debugging. The combined buffer is what we
        // surface as `output` on the SyncResult.
        let result = await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: args,
            environment: env,
            mergeStreams: true
        )
        return SyncResult(
            playlistName: playlistNames.joined(separator: ", "),
            success: result.ok,
            output: result.stdout
        )
    }
}
