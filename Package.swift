// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Ultravox",

    platforms: [
        .iOS(.v13),
        .macOS(.v10_15), // No way to only build for iOS. WTF Apple.
    ],
    products: [
        .library(
            name: "Ultravox",
            targets: ["Ultravox"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", .upToNextMajor(from: "2.0.16")),
    ],
    targets: [
        .target(
            name: "Ultravox",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ]
        ),
    ]
)
