// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StereoPlayer3D",
    platforms: [
        .macOS(.v13)  // macOS 13 Ventura (minimum for Metal 3)
    ],
    products: [
        .executable(
            name: "StereoPlayer3D",
            targets: ["StereoPlayer3D"]
        ),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "StereoPlayer3D",
            dependencies: [],
            path: "Sources",
            resources: [
                .process("Resources/"),
                .process("Metal/StereoWarp.metal"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=complete"),
                .define("STEREO_AUTOPLAY"),
            ],
        ),

        // Test targets
        .testTarget(
            name: "StereoPlayer3DTests",
            dependencies: ["StereoPlayer3D"],
            path: "Tests/StereoPlayer3DTests"
        ),
    ]
)
