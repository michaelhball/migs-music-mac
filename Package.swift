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
    dependencies: [
        // Sparkle handles the "click Install → app quits, replaces itself, relaunches
        // into the new version" experience that's standard for non-App-Store Mac apps.
        // Pinned to a 2.x major; the API is stable across 2.x.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "MigsMusicMac",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MigsMusicMac",
            // iTunesLibrary lets us read the Music.app library directly from its
            // binary store — orders of magnitude faster than the AppleScript path.
            // System framework, ships with macOS 10.13+; our deployment target is 13.
            linkerSettings: [
                .linkedFramework("iTunesLibrary"),
                // rpath into the .app's Frameworks dir so Sparkle.framework loads at
                // runtime. SwiftPM's default rpath (@loader_path only) doesn't reach
                // there because we relocate the binary into Contents/MacOS/ during
                // build.sh's bundle assembly. Without this the app fails to launch
                // with a "Library not loaded: @rpath/Sparkle.framework/..." error.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
