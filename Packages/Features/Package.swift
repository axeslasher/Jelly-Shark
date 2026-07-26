// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Features",
    platforms: [
        .tvOS(.v26),
        // Spelled as a string because `SupportedPlatform.VisionOSVersion` only
        // goes to major-version granularity (`.v26`); the app target's
        // XROS_DEPLOYMENT_TARGET is 26.2 and the manifest must not permit less.
        .visionOS("26.2"),
    ],
    products: [
        .library(
            name: "Features",
            targets: ["Features"],
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
            ],
        ),
        .testTarget(
            name: "FeaturesTests",
            dependencies: ["Features"],
        ),
    ],
)
