// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "JellyfinKit",
    platforms: [
        .tvOS(.v26),
        // Spelled as a string because `SupportedPlatform.VisionOSVersion` only
        // goes to major-version granularity (`.v26`); the app target's
        // XROS_DEPLOYMENT_TARGET is 26.2 and the manifest must not permit less.
        .visionOS("26.2"),
        // Not a shipping platform. JellyfinKit is pure logic and its Keychain
        // tests need a real keychain, so the suite runs on the Mac host via
        // `swift test` (see the Makefile). Without an explicit floor SPM
        // assumes macOS 10.13 for the host build, below the macOS 10.15 that
        // JellyfinAPI and Get require, and resolution fails before compiling.
        // v15 because the SwiftData cache (`#Unique`, macOS 15) also builds
        // and tests on the host.
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "JellyfinKit",
            targets: ["JellyfinKit"],
        ),
    ],
    dependencies: [
        // upToNextMinor, not `from:` — the SDK is pre-1.0, and SPM's `from:` is
        // up-to-next-MAJOR at every version, so `from: "0.6.0"` would accept any
        // 0.x release. On a 0.x library that is where breaking changes land.
        // (Unlike npm, SPM does not special-case 0.x the way `^0.6.0` does.)
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift.git", .upToNextMinor(from: "0.6.0")),
        // Also a dependency of jellyfin-sdk-swift; declared directly because
        // JellyfinClient imports Get to translate its transport errors. Left on
        // up-to-next-major: Get is past 1.0 and follows semver.
        .package(url: "https://github.com/kean/Get", from: "2.1.6"),
    ],
    targets: [
        .target(
            name: "JellyfinKit",
            dependencies: [
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
                .product(name: "Get", package: "Get"),
            ],
        ),
        .testTarget(
            name: "JellyfinKitTests",
            dependencies: ["JellyfinKit"],
        ),
    ],
)
