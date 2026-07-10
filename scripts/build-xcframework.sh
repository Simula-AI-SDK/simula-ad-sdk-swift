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
#
# Outputs (under build/):
#   SimulaAdSDK.xcframework
#   SimulaAdSDK.xcframework.zip
#   SimulaAdSDK.xcframework.zip.checksum   (SPM binaryTarget checksum)

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="SimulaAdSDK"
BUILD_DIR="$PWD/build"
BUNDLE_NAME="SimulaAdSDK_SimulaAdSDK.bundle"

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

  # --- Assertions: fail the release rather than ship a broken artifact ---
  ls "$fw/Modules/$SCHEME.swiftmodule/"*.swiftinterface >/dev/null \
    || { echo "ERROR: no .swiftinterface in $slice slice (library evolution not applied)"; exit 1; }
  [[ -f "$fw/$BUNDLE_NAME/PrivacyInfo.xcprivacy" ]] \
    || { echo "ERROR: PrivacyInfo.xcprivacy missing from resource bundle in $slice slice"; exit 1; }
  [[ -f "$fw/$BUNDLE_NAME/game_icon.png" ]] \
    || { echo "ERROR: bundled images missing from resource bundle in $slice slice"; exit 1; }
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

echo "==> Done"
echo "    artifact: build/$SCHEME.xcframework.zip"
echo "    checksum: $(cat "$BUILD_DIR/$SCHEME.xcframework.zip.checksum")"
