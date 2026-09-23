// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "YaprflowCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "YaprflowCore", targets: ["YaprflowCore"]),
    ],
    targets: [
        .target(
            name: "YaprflowCore",
            path: "Shared"
        ),
        .testTarget(
            name: "YaprflowCoreTests",
            dependencies: ["YaprflowCore"],
            path: "Tests/YaprflowCoreTests"
        ),
    ]
)
