// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MusicBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MusicBar",
            path: "Sources/MusicBar"
        ),
        .testTarget(
            name: "MusicBarTests",
            dependencies: ["MusicBar"]
        ),
    ]
)
