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
        return results
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
