// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "dictate",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", "0.9.0"..<"0.16.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.17.1"),
    ],
    targets: [
        // Transcription engine, prompt + logger. Shared by the app and dictate-eval;
        // must not depend on Sentry or any UI.
        .target(
            name: "DictateCore",
            dependencies: ["WhisperKit"],
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
            dependencies: ["DictateCore", "WhisperKit"],
            path: "Sources/dictate-eval"
        ),
        .testTarget(
            name: "dictateTests",
            dependencies: ["dictate", "DictateCore", "dictate-eval", "WhisperKit"],
            path: "Tests"
        ),
    ]
)
