// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimulaAdSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        // Dynamic so `xcodebuild archive` emits a real SimulaAdSDK.framework — the input for the
        // binary XCFramework release artifact (scripts/build-xcframework.sh). Also gives dynamic
        // linkage for source consumers, which keeps MetricKit crash attribution working (the
        // SimulaAdSDK binary name appears in call-stack trees — see SimulaCrashGuard).
        .library(
            name: "SimulaAdSDK",
            type: .dynamic,
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
