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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1")
    ],
    targets: [
        .target(
            name: "FacePassCore"
        ),
        .executableTarget(
            name: "FacePass",
            dependencies: [
                "FacePassCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "FacePassCoreTests",
            dependencies: ["FacePassCore"]
        )
    ]
)
