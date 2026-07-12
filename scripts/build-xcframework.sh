#!/usr/bin/env bash
#
# Builds the binary release artifact: SimulaAdSDK.xcframework (+ zip + SPM checksum).
#
# WHY BINARY: affected host Xcodes (Swift 6.1-6.3 optimizers) miscompile Swift Concurrency
# closure shapes in *source* SDKs into task-teardown aborts inside host apps
# ("freed pointer was not the last allocation"). Shipping a prebuilt, module-stable
# framework means the host toolchain never compiles SDK implementation code.
# Full history: .cursor/skills/swift-concurrency-task-shape/SKILL.md
#
# The builder toolchain is pinned + validated in .github/workflows/release.yml; running
# this script locally with a different Xcode produces a NON-releasable artifact.
#
# Usage:
#   scripts/build-xcframework.sh
#
# Env:
#   CODESIGN_IDENTITY  optional "Apple Distribution: ..." identity to sign the xcframework.
#   SIMULA_VERSION     version stamped into the framework Info.plist (MARKETING_VERSION).
#                      Defaults to the podspec's s.version.
#
# Outputs (under build/):
#   SimulaAdSDK.xcframework
#   SimulaAdSDK.xcframework.zip
#   SimulaAdSDK.xcframework.zip.checksum   (SPM binaryTarget checksum == zip SHA-256)
#   SimulaAdSDK.dSYMs.zip                  (standalone copy for backend symbolication)

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="SimulaAdSDK"
BUILD_DIR="$PWD/build"
BUNDLE_NAME="SimulaAdSDK_SimulaAdSDK.bundle"

# Version stamp for the framework Info.plist — otherwise App Store Connect SDK reporting
# and dSYM bookkeeping see a default (1.0) version.
VERSION="${SIMULA_VERSION:-$(sed -nE 's/^ *s\.version *= *"([^"]+)".*/\1/p' SimulaAdSDK.podspec)}"
[[ -n "$VERSION" ]] || { echo "ERROR: could not resolve version (set SIMULA_VERSION or fix the podspec)"; exit 1; }
# Info.plist version keys must be period-separated integers (App Store validation rejects
# prerelease suffixes in embedded frameworks) — strip any "-beta.N" for the plist stamp only.
# Telemetry's SIMULA_SDK_VERSION keeps the full prerelease string.
PLIST_VERSION="${VERSION%%-*}"
echo "==> Building $SCHEME $VERSION (Info.plist version $PLIST_VERSION)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Archive one slice and assemble a distributable framework from it ---------------------
# xcodebuild archive of a Swift package puts the bare framework (binary + Info.plist) in the
# archive, but leaves the swiftmodule (with the .swiftinterface files that make the framework
# consumable by any newer Swift compiler) and the package resource bundle in the archive
# intermediates. Assemble all three into one framework per slice.
archive_slice() {
  local destination="$1" slice="$2" products_subdir="$3"
  local archive="$BUILD_DIR/$slice.xcarchive"
  local dd="$BUILD_DIR/dd-$slice"

  echo "==> Archiving $slice"
  xcodebuild archive \
    -scheme "$SCHEME" \
    -destination "$destination" \
    -archivePath "$archive" \
    -derivedDataPath "$dd" \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    SKIP_INSTALL=NO \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$PLIST_VERSION" \
    CURRENT_PROJECT_VERSION="$PLIST_VERSION" \
    | tail -2

  local fw="$archive/Products/usr/local/lib/$SCHEME.framework"
  local products="$dd/Build/Intermediates.noindex/ArchiveIntermediates/$SCHEME/BuildProductsPath/$products_subdir"

  # Module (with .swiftinterface) into the framework. ditto (not cp -R): the build products
  # can be symlinks into derived-data intermediates; ditto materializes real files.
  mkdir -p "$fw/Modules"
  ditto "$products/$SCHEME.swiftmodule" "$fw/Modules/$SCHEME.swiftmodule"

  # Package resource bundle into the framework root: the SPM-generated Bundle.module
  # accessor probes Bundle(for:).resourceURL (= the framework root) and calls fatalError
  # when the bundle is missing — embedding it here is a hard correctness requirement.
  ditto "$products/$BUNDLE_NAME" "$fw/$BUNDLE_NAME"

  # Privacy manifest ALSO at the framework root (next to Info.plist): App Store Connect
  # scans framework bundle roots for third-party SDK manifests. The copy inside the
  # resource bundle stays for Bundle.module consumers; this one is for Apple's scanner.
  cp "$fw/$BUNDLE_NAME/PrivacyInfo.xcprivacy" "$fw/PrivacyInfo.xcprivacy"

  # --- Assertions: fail the release rather than ship a broken artifact ---
  ls "$fw/Modules/$SCHEME.swiftmodule/"*.swiftinterface >/dev/null \
    || { echo "ERROR: no .swiftinterface in $slice slice (library evolution not applied)"; exit 1; }
  # Every resource declared in Package.swift: the generated Bundle.module accessor
  # fatalErrors on a missing bundle, and UI code loads each of these at runtime.
  local resource
  for resource in \
    PrivacyInfo.xcprivacy \
    game_icon.png \
    games_unavailable.png \
    minigame_interstitial_background.png; do
    [[ -f "$fw/$BUNDLE_NAME/$resource" ]] \
      || { echo "ERROR: $resource missing from resource bundle in $slice slice"; exit 1; }
  done
  [[ -f "$fw/PrivacyInfo.xcprivacy" ]] \
    || { echo "ERROR: PrivacyInfo.xcprivacy missing from framework root in $slice slice"; exit 1; }
}

archive_slice "generic/platform=iOS"           "ios"           "Release-iphoneos"
archive_slice "generic/platform=iOS Simulator" "ios-simulator" "Release-iphonesimulator"

# --- Compose the XCFramework (with dSYMs so hosts keep symbolicated crash reports) --------
echo "==> Creating XCFramework"
xcodebuild -create-xcframework \
  -framework "$BUILD_DIR/ios.xcarchive/Products/usr/local/lib/$SCHEME.framework" \
  -debug-symbols "$BUILD_DIR/ios.xcarchive/dSYMs/$SCHEME.framework.dSYM" \
  -framework "$BUILD_DIR/ios-simulator.xcarchive/Products/usr/local/lib/$SCHEME.framework" \
  -debug-symbols "$BUILD_DIR/ios-simulator.xcarchive/dSYMs/$SCHEME.framework.dSYM" \
  -output "$BUILD_DIR/$SCHEME.xcframework"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> Signing"
  codesign --timestamp --sign "$CODESIGN_IDENTITY" "$BUILD_DIR/$SCHEME.xcframework"
fi

# --- Zip + SPM checksum --------------------------------------------------------------------
echo "==> Zipping"
ditto -c -k --keepParent "$BUILD_DIR/$SCHEME.xcframework" "$BUILD_DIR/$SCHEME.xcframework.zip"
swift package compute-checksum "$BUILD_DIR/$SCHEME.xcframework.zip" \
  > "$BUILD_DIR/$SCHEME.xcframework.zip.checksum"

# Standalone dSYM zip: the crash guard's MetricKit path relies on server-side dSYM
# symbolication, so the backend needs the dSYMs without unpacking the whole xcframework.
DSYM_STAGE="$BUILD_DIR/dSYMs-$VERSION"
mkdir -p "$DSYM_STAGE/ios" "$DSYM_STAGE/ios-simulator"
ditto "$BUILD_DIR/ios.xcarchive/dSYMs/$SCHEME.framework.dSYM" "$DSYM_STAGE/ios/$SCHEME.framework.dSYM"
ditto "$BUILD_DIR/ios-simulator.xcarchive/dSYMs/$SCHEME.framework.dSYM" "$DSYM_STAGE/ios-simulator/$SCHEME.framework.dSYM"
ditto -c -k --keepParent "$DSYM_STAGE" "$BUILD_DIR/$SCHEME.dSYMs.zip"

echo "==> Done"
echo "    artifact: build/$SCHEME.xcframework.zip"
echo "    dSYMs:    build/$SCHEME.dSYMs.zip"
echo "    checksum: $(cat "$BUILD_DIR/$SCHEME.xcframework.zip.checksum")"
