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
        .executableTarget(
            name: "dictate",
            dependencies: [
                "WhisperKit",
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "dictateTests",
            dependencies: ["dictate"],
            path: "Tests"
        )
    ]
)
