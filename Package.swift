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
        // IAB Open Measurement SDK (OMID) 1.6.6, partner-namespaced as "Simulaad".
        // Committed binary; iOS-only (the package also supports macOS, where it is unused).
        .binaryTarget(
            name: "OMSDK_Simulaad",
            path: "Frameworks/OMSDK_Simulaad.xcframework"
        ),
        .target(
            name: "SimulaAdSDK",
            dependencies: [
                // Conditional so the macOS slice of this package builds without the
                // iOS/tvOS-only framework. All OMID code is additionally guarded by
                // `#if canImport(OMSDK_Simulaad)`.
                .target(name: "OMSDK_Simulaad", condition: .when(platforms: [.iOS]))
            ],
            path: "Sources/SimulaAdSDK",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
                .copy("Resources/games_unavailable.png"),
                .copy("Resources/minigame_interstitial_background.png"),
                .copy("Resources/game_icon.png"),
                .copy("Resources/omsdk-v1.js")
            ]
        ),
        .testTarget(
            name: "SimulaAdSDKTests",
            dependencies: ["SimulaAdSDK"],
            path: "Tests/SimulaAdSDKTests"
        ),
    ]
)
