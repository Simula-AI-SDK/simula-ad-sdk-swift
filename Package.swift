// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimulaAdSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "SimulaAdSDK",
            targets: ["SimulaAdSDK"]
        ),
    ],
    targets: [
        .target(
            name: "SimulaAdSDK",
            path: "Sources/SimulaAdSDK",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
                .copy("Resources/games_unavailable.png"),
                .copy("Resources/minigame_interstitial_background.png"),
                .copy("Resources/game_icon.png")
            ]
        ),
        .testTarget(
            name: "SimulaAdSDKTests",
            dependencies: ["SimulaAdSDK"],
            path: "Tests/SimulaAdSDKTests"
        ),
    ]
)
