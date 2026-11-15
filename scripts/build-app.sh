#!/bin/sh
# Builds build/TimeFinder.app via the Xcode project (requires Xcode 16+ selected with xcode-select).
# Usage: scripts/build-app.sh [Debug|Release]   (default: Release)
#
# Signing: ad-hoc by default; create Config/Local.xcconfig (see Config/Local.xcconfig.example)
# to sign with your own team so macOS privacy permissions survive rebuilds.
set -eu
cd "$(dirname "$0")/.."

CONFIG=${1:-Release}
DERIVED=build/DerivedData

xcodebuild -project TimeFinder.xcodeproj -scheme TimeFinder -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
  -destination "platform=macOS,arch=$(uname -m)" -quiet build

rm -rf build/TimeFinder.app
ditto "$DERIVED/Build/Products/$CONFIG/TimeFinder.app" build/TimeFinder.app
echo "Built build/TimeFinder.app ($CONFIG)"
