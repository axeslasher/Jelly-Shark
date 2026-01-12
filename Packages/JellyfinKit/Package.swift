// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "JellyfinKit",
    platforms: [
        .macOS(.v15),
        .tvOS(.v26),
        .visionOS(.v26)
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
