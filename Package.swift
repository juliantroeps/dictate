// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "dictate",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", .upToNextMinor(from: "1.1.1")),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.17.1"),
    ],
    targets: [
        // Transcription engine, prompt + logger. Shared by the app and dictate-eval;
        // must not depend on Sentry or any UI.
        .target(
            name: "DictateCore",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            path: "Sources/DictateCore"
        ),
        .executableTarget(
            name: "dictate",
            dependencies: [
                "DictateCore",
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Sources",
            exclude: ["DictateCore", "dictate-eval"]
        ),
        // Offline transcription eval harness (see eval/README.md).
        .executableTarget(
            name: "dictate-eval",
            dependencies: ["DictateCore", .product(name: "WhisperKit", package: "argmax-oss-swift")],
            path: "Sources/dictate-eval"
        ),
        .testTarget(
            name: "dictateTests",
            dependencies: ["dictate", "DictateCore", "dictate-eval", .product(name: "WhisperKit", package: "argmax-oss-swift")],
            path: "Tests"
        ),
    ]
)
