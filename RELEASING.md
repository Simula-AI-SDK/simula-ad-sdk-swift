# Releasing the iOS SDK

The iOS SDK is distributed as the same binary XCFramework through Swift Package Manager and
CocoaPods. `.github/workflows/release.yml` performs the complete release from a source commit on
`main`; do not create the release tag or push the pod manually first.

## One-time GitHub setup

Create a `Cocoa Pod` environment and add this environment secret:

- `COCOAPODS_TRUNK_TOKEN`: token from `~/.netrc` after `pod trunk register`

Allow GitHub Actions to write repository contents so the workflow can push the binary release tag
and create the GitHub release. Protect `main` and release tags, while allowing the release workflow
to create tags after any configured environment approval.

## Release steps

1. Update `s.version` in `SimulaAdSDK.podspec` and `SIMULA_SDK_VERSION` in
   `Sources/SimulaAdSDK/Telemetry/Telemetry.swift` to the same semantic version.
2. Keep the source `Package.swift` on `main`; never commit a binary manifest to `main`.
3. Run `swift build` and `swift test`, then merge the version change after CI passes.
4. In GitHub Actions, run **Release XCFramework and CocoaPods** from `main` and enter the version
   without a leading `v`, for example `1.2.3`.

The workflow rejects an existing Git tag, GitHub release, or CocoaPods version. It tests with the
pinned release compiler, builds and validates the XCFramework, lints the local binary pod, creates a
tag-only commit containing the binary SwiftPM manifest and CocoaPods SHA-256 constraint, publishes
and verifies the GitHub asset, and finally pushes the pod to trunk.

If the workflow fails after the GitHub release is published but before CocoaPods accepts the pod,
inspect the failed trunk output and retry only `pod trunk push` from the generated release tag and
the verified GitHub asset. Never replace an asset or reuse a published version.
