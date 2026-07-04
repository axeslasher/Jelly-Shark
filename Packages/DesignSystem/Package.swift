// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [
        .macOS(.v15),
        .tvOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(
            name: "DesignSystem",
            targets: ["DesignSystem"]
        ),
    ],
    targets: [
        .target(
            name: "DesignSystem",
            resources: [
                // Bundles the Fontshare .ttf files (and FONTS.md) into the module.
                // The .ttf binaries are git-ignored — see Resources/Fonts/FONTS.md.
                // The build works whether or not the fonts are present; styles fall
                // back to the system font when they're missing.
                .process("Resources/Fonts")
            ]
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem"]
        ),
    ]
)
