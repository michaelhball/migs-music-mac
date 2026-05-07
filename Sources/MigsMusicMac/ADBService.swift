import Foundation

/// Status of the ADB-connected device check.
enum DeviceState: Equatable {
    case noAdb              // adb binary not found on PATH
    case noDevice           // adb works but no device connected
    case unauthorized       // device connected but USB debugging not authorized
    case connected(serial: String)
}

enum ADBService {
    /// Where to look for `adb`. Most users install via Android SDK Platform Tools; covers
    /// the common Homebrew + manual-extract locations. Falling back to PATH lookup last.
    private static let candidatePaths: [String] = [
        "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        "/usr/local/bin/adb",
        "/opt/homebrew/bin/adb",
        "/usr/bin/adb",
    ]

    /// Resolves the path to the `adb` binary, or nil if not found. Sync — the lookup is a
    /// few stat() calls in the common case. Callers cache the result implicitly because
    /// adb's install location doesn't change at runtime.
    static func adbPath() -> String? {
        for candidate in candidatePaths where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Last resort: shell `which`. /usr/bin/which inherits a minimal PATH so this isn't
        // reliable from a .app bundle — that's why we check the explicit paths first.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["adb"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Checks whether a device is currently connected and authorised. `adb devices` output:
    ///
    ///     List of devices attached
    ///     XXXX	device                 ← connected + authorised
    ///     YYYY	unauthorized           ← cable plugged but user hasn't accepted the dialog
    ///
    /// We pick the first authorised device. Multi-device support is a future concern.
    static func deviceState() async -> DeviceState {
        guard let adb = adbPath() else { return .noAdb }
        let result = await ProcessRunner.run(executable: adb, arguments: ["devices"])

        var hasUnauthorised = false
        for line in result.stdout.split(separator: "\n").dropFirst() { // skip the "List of devices…" header
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[1] {
            case "device":
                return .connected(serial: parts[0])
            case "unauthorized":
                hasUnauthorised = true
            default:
                continue
            }
        }
        return hasUnauthorised ? .unauthorized : .noDevice
    }
}
