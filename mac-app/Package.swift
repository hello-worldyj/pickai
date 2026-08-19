// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PickAI",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PickAI",
            path: "Sources/PickAI"
        )
    ]
)
