// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "dikt",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "dikt",
            path: "Sources"
        )
    ]
)
