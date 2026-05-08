// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MigsMusicMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MigsMusicMac", targets: ["MigsMusicMac"]),
        // Tiny CLI helper that sync-playlist-to-phone.sh uses to dump a playlist's
        // track list via ITLibrary. Replaces a per-sync `osascript` invocation
        // (200ms minimum + linear-in-track-count Music.app IPC); ITLibrary reads
        // from the on-disk library binary in tens of ms regardless of playlist size.
        .executable(name: "migs-tracks", targets: ["MigsTracks"]),
    ],
    targets: [
        .executableTarget(
            name: "MigsMusicMac",
            path: "Sources/MigsMusicMac",
            // iTunesLibrary lets us read the Music.app library directly from its
            // binary store — orders of magnitude faster than the AppleScript path.
            // System framework, ships with macOS 10.13+; our deployment target is 13.
            linkerSettings: [
                .linkedFramework("iTunesLibrary"),
            ]
        ),
        .executableTarget(
            name: "MigsTracks",
            path: "Sources/MigsTracks",
            linkerSettings: [
                .linkedFramework("iTunesLibrary"),
            ]
        ),
    ]
)
