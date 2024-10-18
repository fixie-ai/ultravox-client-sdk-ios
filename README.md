# Ultravox client SDK for iOS
iOS client SDK for [Ultravox](https://ultravox.ai).

[![swift package](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffixie-ai%2Fultravox-client-sdk-ios%2Fbadge%3Ftype%3Dswift-versions&color=orange)](https://swiftpackageindex.com/fixie-ai/ultravox-client-sdk-ios)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffixie-ai%2Fultravox-client-sdk-ios%2Fbadge%3Ftype%3Dplatforms&color=orange)](https://swiftpackageindex.com/fixie-ai/ultravox-client-sdk-ios)

## Getting started

Using XCode, under `Project Settings` -> `Swift Packages` add a new package: `https://github.com/fixie-ai/ultravox-client-sdk-ios`

Or you can directly add to your `Package.swift`:

```swift
let package = Package(
  ...
    dependencies: [
        .package(url: "https://github.com/fixie-ai/ultravox-client-sdk-ios.git", .upToNextMajor("0.0.1")),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "Ultravox", package: "ultravox-client-sdk-ios"),
            ]
        ),
    ]
)
```

## Usage

```swift
let session = UltravoxSession()
await session.joinCall(joinUrl: "joinUrlFromYourServer");
await session.leaveCall();
```

See the example app at https://github.com/fixie-ai/ultravox-client-sdk-ios-example for a more complete example. To get a `joinUrl`, you'll want to integrate your server with the [Ultravox REST API](https://fixie-ai.github.io/ultradox/).
