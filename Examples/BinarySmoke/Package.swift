// swift-tools-version: 5.9
//
// Binary-consumer smoke test: consumes the locally built SimulaAdSDK.xcframework the same
// way an SPM host does (binaryTarget), and compiles a client against the .swiftinterface.
// This catches interface breakages (library-evolution violations, missing symbols, artifact
// layout regressions) before a release ships.
//
// Run AFTER scripts/build-xcframework.sh has produced build/SimulaAdSDK.xcframework:
//
//   xcodebuild build -scheme BinarySmoke \
//     -destination 'generic/platform=iOS Simulator' \
//     -skipPackagePluginValidation
//
// (from this directory; see .github/workflows/release.yml for the CI invocation)
import PackageDescription

let package = Package(
    name: "BinarySmoke",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "BinarySmoke", targets: ["BinarySmoke"])
    ],
    targets: [
        .binaryTarget(
            name: "SimulaAdSDK",
            path: "../../build/SimulaAdSDK.xcframework"
        ),
        .target(
            name: "BinarySmoke",
            dependencies: ["SimulaAdSDK"]
        ),
    ]
)
