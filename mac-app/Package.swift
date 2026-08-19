// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PickAI",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "11.0.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS", from: "7.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "PickAI",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
            ],
            path: "Sources/PickAI"
        )
    ]
)
