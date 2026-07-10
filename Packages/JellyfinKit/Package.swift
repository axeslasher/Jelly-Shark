// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "JellyfinKit",
    platforms: [
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
        // Also a dependency of jellyfin-sdk-swift; declared directly because
        // JellyfinClient imports Get to translate its transport errors
        .package(url: "https://github.com/kean/Get", from: "2.1.6"),
    ],
    targets: [
        .target(
            name: "JellyfinKit",
            dependencies: [
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
                .product(name: "Get", package: "Get"),
            ]
        ),
        .testTarget(
            name: "JellyfinKitTests",
            dependencies: ["JellyfinKit"]
        ),
    ]
)
