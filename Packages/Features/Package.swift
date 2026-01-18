// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Features",
    platforms: [
        .macOS(.v15),
        .tvOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(
            name: "Features",
            targets: ["Features"]
        ),
    ],
    dependencies: [
        .package(path: "../JellyfinKit"),
        .package(path: "../DesignSystem"),
    ],
    targets: [
        .target(
            name: "Features",
            dependencies: [
                "JellyfinKit",
                "DesignSystem",
            ]
        ),
        .testTarget(
            name: "FeaturesTests",
            dependencies: ["Features"]
        ),
    ]
)
