// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "geoiq_ios_lk_vision_bot_sdk",
    platforms: [
        .iOS(.v13),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "geoiq_ios_lk_vision_bot_sdk",
            type: .dynamic,
            targets: ["geoiq_ios_lk_vision_bot_sdk"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.4.0")// Core SDK
 
    ],
    targets: [
        .target(
            name: "geoiq_ios_lk_vision_bot_sdk",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ]
        ),
    ]
)



