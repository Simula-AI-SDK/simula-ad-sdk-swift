#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

POD_VERSION=$(ruby -e 'text = File.read("SimulaAdSDK.podspec"); match = text.match(/s\.version\s*=\s*"([^"]+)"/); abort "missing podspec version" unless match; puts match[1]')
SDK_VERSION=$(ruby -e 'text = File.read("Sources/SimulaAdSDK/Telemetry/Telemetry.swift"); match = text.match(/SIMULA_SDK_VERSION\s*=\s*"([^"]+)"/); abort "missing telemetry version" unless match; puts match[1]')

[[ "$POD_VERSION" == "$SDK_VERSION" ]] || {
  echo "ERROR: podspec version ($POD_VERSION) does not match telemetry version ($SDK_VERSION)"
  exit 1
}

PACKAGE_HAS_DEV_DEFINE=false
if grep -Fq '.define("SIMULA_DEV_ARTIFACT")' Package.swift; then
  PACKAGE_HAS_DEV_DEFINE=true
fi

if [[ "$POD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+$ ]]; then
  [[ "$PACKAGE_HAS_DEV_DEFINE" == true ]] || {
    echo "ERROR: dev-tagged version $POD_VERSION requires SIMULA_DEV_ARTIFACT in Package.swift"
    exit 1
  }
  echo "dev"
else
  [[ "$PACKAGE_HAS_DEV_DEFINE" == false ]] || {
    echo "ERROR: stable/non-dev version $POD_VERSION must not define SIMULA_DEV_ARTIFACT"
    exit 1
  }
  echo "production"
fi
