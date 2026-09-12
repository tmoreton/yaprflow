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
        .executable(name: "yaprflow-asr-smoke", targets: ["YaprflowASRSmoke"]),
    ],
    dependencies: [
        .package(path: "Vendor/SherpaOnnxASR"),
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
        .executableTarget(
            name: "YaprflowASRSmoke",
            dependencies: [
                .product(name: "SherpaOnnxASR", package: "SherpaOnnxASR"),
            ],
            path: "Tools/YaprflowASRSmoke"
        ),
    ]
)
