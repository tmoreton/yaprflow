// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SherpaOnnxASR",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "SherpaOnnxASR", targets: ["SherpaOnnx"]),
    ],
    targets: [
        .binaryTarget(
            name: "OnnxRuntimeMacOS",
            path: "Artifacts/OnnxRuntimeMacOS.xcframework"
        ),
        .binaryTarget(
            name: "OnnxRuntimeIOS",
            path: "Artifacts/OnnxRuntimeIOS.xcframework"
        ),
        .binaryTarget(
            name: "SherpaOnnxMacOS",
            path: "Artifacts/SherpaOnnxMacOS.xcframework"
        ),
        .binaryTarget(
            name: "SherpaOnnxIOS",
            path: "Artifacts/SherpaOnnxIOS.xcframework"
        ),
        .target(
            name: "SherpaOnnx",
            dependencies: [
                .target(
                    name: "OnnxRuntimeMacOS",
                    condition: .when(platforms: [.macOS])
                ),
                .target(
                    name: "OnnxRuntimeIOS",
                    condition: .when(platforms: [.iOS])
                ),
                .target(
                    name: "SherpaOnnxMacOS",
                    condition: .when(platforms: [.macOS])
                ),
                .target(
                    name: "SherpaOnnxIOS",
                    condition: .when(platforms: [.iOS])
                ),
            ],
            path: "Sources/SherpaOnnx",
            sources: ["SherpaOnnx.swift"],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
