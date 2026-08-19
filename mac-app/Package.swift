// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PickAI",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "11.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "PickAI",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
            ],
            path: "Sources/PickAI"
        )
    ]
)
