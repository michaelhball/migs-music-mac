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

        var results: [SyncResult] = []
        for (index, name) in playlistNames.enumerated() {
            await MainActor.run { progress(index, playlistNames.count, name) }
            let result = await runSyncScript(scriptURL: scriptURL, playlistName: name)
            results.append(result)
        }

        // After all per-playlist syncs land, push a manifest of the full selected set and
        // re-broadcast AUTO_IMPORT. The receiver picks up the manifest, prunes any synced
        // playlist on the phone whose name isn't in the list (mirror semantics — uncheck a
        // playlist on the Mac, it disappears from the phone), then deletes the manifest.
        // This is best-effort: if it fails, the sync still succeeded for the playlists that
        // were pushed, the user just has stale entries lingering.
        await pushManifestAndBroadcast(playlistNames: playlistNames)
        return results
    }

    private static func pushManifestAndBroadcast(playlistNames: [String]) async {
        guard let adb = ADBService.adbPath() else { return }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("migs-sync-manifest-\(UUID().uuidString).txt")
        // One name per line, UTF-8. Names with embedded newlines would break this (in
        // theory possible from Music.app, in practice essentially never).
        let body = playlistNames.joined(separator: "\n") + "\n"
        do {
            try body.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        await runADB(adb: adb, args: ["push", tempURL.path, "/sdcard/Music/.migs-sync-manifest"])
        // -f 0x20 = FLAG_INCLUDE_STOPPED_PACKAGES, same as the bash script. Without it the
        // broadcast is silently dropped if the app's been force-stopped.
        await runADB(
            adb: adb,
            args: ["shell", "am broadcast -a com.migsmusic.AUTO_IMPORT -p com.migsmusic -f 0x20"]
        )
    }

    /// Fire-and-wait runner for arbitrary `adb` invocations. Output is discarded — the
    /// caller can't usefully act on errors from these helper commands beyond logging.
    private static func runADB(adb: String, args: [String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: adb)
                task.arguments = args
                let devnull = Pipe()
                task.standardOutput = devnull
                task.standardError = devnull
                try? task.run()
                task.waitUntilExit()
                continuation.resume()
            }
        }
    }

    /// Looks up the bundled bash script. build.sh copies it under Contents/Resources/ as
    /// `sync-playlist-to-phone.sh`. Bundle.main.url(forResource:withExtension:) handles the
    /// usual ./.app/Contents/Resources/ probe automatically.
    private static func bundledScriptURL() -> URL? {
        Bundle.main.url(forResource: "sync-playlist-to-phone", withExtension: "sh")
    }

    private static func runSyncScript(scriptURL: URL, playlistName: String) async -> SyncResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = [scriptURL.path, playlistName]
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
                task.environment = env

                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe

                do {
                    try task.run()
                } catch {
                    continuation.resume(
                        returning: SyncResult(
                            playlistName: playlistName,
                            success: false,
                            output: "Failed to launch script: \(error.localizedDescription)"
                        )
                    )
                    return
                }
                task.waitUntilExit()
                let output = String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                continuation.resume(
                    returning: SyncResult(
                        playlistName: playlistName,
                        success: task.terminationStatus == 0,
                        output: output
                    )
                )
            }
        }
    }
}
