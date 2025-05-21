# Ultravox client SDK for iOS
iOS client SDK for [Ultravox](https://ultravox.ai).

[![swift package](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffixie-ai%2Fultravox-client-sdk-ios%2Fbadge%3Ftype%3Dswift-versions&color=orange)](https://swiftpackageindex.com/fixie-ai/ultravox-client-sdk-ios)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffixie-ai%2Fultravox-client-sdk-ios%2Fbadge%3Ftype%3Dplatforms&color=orange)](https://swiftpackageindex.com/fixie-ai/ultravox-client-sdk-ios)

## Getting started

### iOS app (in XCode)

If you're starting from scratch, strongly consider building with [Flutter](https://flutter.dev/) instead.

If you're not starting from scratch then you probably already know how to add this as a dependency, but it will look something like this:

1. `import Ultravox` in any file. After a few seconds you'll see an error about "No such module."
1. Click on the error and it should give you the option to search package collections. Do so.
1. Paste this in your search bar (top right) and hit enter: `https://github.com/fixie-ai/ultravox-client-sdk-ios`
1. This package should be found and this README should be rendered.  Click `Add Package`.
1. Pick your App target and again click `Add Package`.
1. Increment your XCode frustrations counter and consider switching to Flutter. 😉

See [Apple's documentation](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app#Add-a-package-dependency) for more info.

### Swift Package
If you're building a package, add this to your `Package.swift`:

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

For a complete example, see https://github.com/fixie-ai/ultravox-client-sdk-ios-example.

To get a `joinUrl`, you'll want to integrate your server with the [Ultravox REST API](https://fixie-ai.github.io/ultradox/).

# Development:
Run [swiftformat](https://swiftpackageindex.com/nicklockwood/SwiftFormat) to properly format the code.

## Release Process
1. Update the sdkVersion constant at the top of Ultravox.swift. This is also the tag you'll use below. It MUST follow semantic versioning.

1. Get your change reviewed and merged.

1. Create & push a new tag:
`git tag <new sdkVersion>`
`git push --tags origin main`

1. Create a new release in GitHub please. It should use the same sdkVersion as its name.
