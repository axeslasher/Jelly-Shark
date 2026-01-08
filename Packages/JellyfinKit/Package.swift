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
    dependencies: [
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "JellyfinKit",
            dependencies: [
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "JellyfinKitTests",
            dependencies: ["JellyfinKit"]
        ),
    ]
)
