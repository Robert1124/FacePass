// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FacePass",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "FacePassCore",
            targets: ["FacePassCore"]
        ),
        .executable(
            name: "FacePass",
            targets: ["FacePass"]
        )
    ],
    targets: [
        .target(
            name: "FacePassCore"
        ),
        .executableTarget(
            name: "FacePass",
            dependencies: ["FacePassCore"]
        ),
        .testTarget(
            name: "FacePassCoreTests",
            dependencies: ["FacePassCore"]
        )
    ]
)
