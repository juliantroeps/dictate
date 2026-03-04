// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "dikt",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", "0.9.0"..<"0.16.0"),
    ],
    targets: [
        .executableTarget(
            name: "dikt",
            dependencies: ["WhisperKit"],
            path: "Sources"
        )
    ]
)
