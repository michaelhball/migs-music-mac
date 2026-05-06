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
            path: "Sources/MigsMusicMac"
        ),
    ]
)
