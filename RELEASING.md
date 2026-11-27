# Releasing the iOS SDK

The iOS SDK is distributed as a binary XCFramework through Swift Package Manager.
`.github/workflows/release.yml` creates the release tag and publishes the XCFramework from a
source commit on `main`.

## One-time GitHub setup

Allow GitHub Actions to write repository contents so the workflow can push the binary release tag
and create the GitHub release. Protect `main` and release tags, while allowing the release workflow
to create tags.

## Release steps

1. Set `SIMULA_SDK_VERSION` in `Sources/SimulaAdSDK/Telemetry/Telemetry.swift` to the new version.
2. Keep `SIMULA_DEV_ARTIFACT` in the source `Package.swift` only for an exact `-dev.N` version;
   remove it for stable and other prerelease versions. `scripts/validate-artifact-flavor.sh` enforces
   this and the XCFramework builder scans stable binaries for the staging hostname. A dev artifact
   selects staging when the host Info.plist Boolean `SimulaStagingEnvironmentEnabled` is set to
   `true`; `devMode` does not choose the backend.
3. Keep the source `Package.swift` on `main`; never commit a binary manifest to `main`.
4. Run `swift build` and `swift test`, then merge the version change after CI passes.
5. In GitHub Actions, run **Release Swift Package** from `main` and enter the version
   without a leading `v`, for example `1.2.3`.

The workflow rejects an existing Git tag or GitHub release. It tests with the pinned release
compiler, builds and validates the XCFramework, creates a tag-only commit containing the binary
SwiftPM manifest, and verifies that the published GitHub asset matches the manifest checksum.
Never replace an asset or reuse a published version.
