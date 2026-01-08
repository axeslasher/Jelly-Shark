// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "JellyfinKit",
    platforms: [
        .tvOS(.v26),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "JellyfinKit",
            targets: ["JellyfinKit"]
        ),
    ],
    targets: [
        .target(
            name: "JellyfinKit"
        ),
        .testTarget(
            name: "JellyfinKitTests",
            dependencies: ["JellyfinKit"]
        ),
    ]
)
