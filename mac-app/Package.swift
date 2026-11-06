// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PickAI",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CapsLockHelper",
            path: "Sources/CapsLockHelper",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "PickAI",
            dependencies: ["CapsLockHelper"],
            path: "Sources/PickAI"
        )
    ]
)
