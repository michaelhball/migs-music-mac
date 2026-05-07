import Foundation

/// Runs subprocesses without the classic Process+Pipe deadlock. The naive pattern of
/// `task.run() → task.waitUntilExit() → readDataToEndOfFile()` blocks if the child writes
/// more than the OS pipe buffer (~64KB on macOS) before exiting: the child blocks waiting
/// for someone to drain the pipe, while we're blocked in `waitUntilExit()`.
///
/// We solve it by attaching a `readabilityHandler` that drains the pipe concurrently while
/// the process runs. After exit, we detach the handler and append any tail data.
enum ProcessRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var combined: String { stdout + stderr }
        var ok: Bool { exitCode == 0 }
    }

    /// Async runner. `mergeStreams = true` writes both stdout and stderr into the same
    /// buffer (used by SyncOrchestrator where the bash script's stderr is just more log
    /// lines we want chronologically interleaved); otherwise they're collected separately.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        mergeStreams: Bool = false
    ) async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executable)
                task.arguments = arguments
                if let environment = environment { task.environment = environment }

                let outPipe = Pipe()
                let errPipe = mergeStreams ? outPipe : Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe

                let lock = NSLock()
                var outData = Data()
                var errData = Data()

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    lock.lock(); outData.append(chunk); lock.unlock()
                }
                if !mergeStreams {
                    errPipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        lock.lock(); errData.append(chunk); lock.unlock()
                    }
                }

                do {
                    try task.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(
                        returning: Result(
                            stdout: "",
                            stderr: "Failed to launch \(executable): \(error.localizedDescription)",
                            exitCode: -1
                        )
                    )
                    return
                }

                task.waitUntilExit()

                // Detach handlers and drain anything still buffered. The handler stops being
                // called once we set it to nil; any data written between the last handler
                // invocation and exit is still in the pipe and we collect it here.
                outPipe.fileHandleForReading.readabilityHandler = nil
                if !mergeStreams { errPipe.fileHandleForReading.readabilityHandler = nil }
                let outTail = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errTail = mergeStreams ? Data() : ((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())
                lock.lock()
                outData.append(outTail)
                errData.append(errTail)
                lock.unlock()

                continuation.resume(
                    returning: Result(
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? "",
                        exitCode: task.terminationStatus
                    )
                )
            }
        }
    }
}
