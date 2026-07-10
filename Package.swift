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
        // Dev-only "module zoo" for the Release-mode concurrency canary: two extra Swift
        // modules whose async thunks are byte-identical to each other's (and to common SDK
        // shapes), so a Release test link reproduces the multi-module fold/coalesce pressure
        // of real host apps (many ad SDKs in one binary). Not part of any product.
        // See .cursor/skills/swift-concurrency-task-shape/SKILL.md.
        .target(
            name: "SimulaCanaryZooA",
            path: "Tests/CanaryZoo/SimulaCanaryZooA"
        ),
        .target(
            name: "SimulaCanaryZooB",
            path: "Tests/CanaryZoo/SimulaCanaryZooB"
        ),
        .testTarget(
            name: "SimulaAdSDKTests",
            dependencies: ["SimulaAdSDK", "SimulaCanaryZooA", "SimulaCanaryZooB"],
            path: "Tests/SimulaAdSDKTests"
        ),
    ]
)
