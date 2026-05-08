// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MigsMusicMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MigsMusicMac", targets: ["MigsMusicMac"]),
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
    ]
)
