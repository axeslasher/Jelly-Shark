// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Features",
    defaultLocalization: "en",
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
        // Spike #60 only: breaks the binary-dependency policy on purpose
        // (docs/spikes/60.md). Pinned to the minor because upstream ships
        // roughly daily; no optional traits.
        // 7.71.0 is the first release with the AE#1052 marker fixes this
        // spike reported and tested (E18 to E20).
        .package(url: "https://github.com/superuser404notfound/AetherEngine", .upToNextMinor(from: "7.76.0")),
    ],
    targets: [
        .target(
            name: "Features",
            dependencies: [
                "JellyfinKit",
                "DesignSystem",
                .product(name: "AetherEngine", package: "AetherEngine"),
            ],
            resources: [
                .process("Localizable.xcstrings"),
            ],
        ),
        .testTarget(
            name: "FeaturesTests",
            dependencies: ["Features"],
            resources: [
                // Real ffmpeg-muxed MKV (same file as JellyfinKit's copy)
                // backing the remux HLS server's HTTP protocol tests.
                .copy("Fixtures"),
            ],
        ),
    ],
)
