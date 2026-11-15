#!/bin/sh
# Builds a signed release of TimeFinder for GitHub Releases and the Homebrew tap.
#
#   scripts/release.sh 0.1.0             # build + verify; prints the cask, publishes nothing
#   scripts/release.sh 0.1.0 --publish   # also tags, creates the GitHub release, updates the tap
#
# Signing uses a self-signed code-signing certificate (default name below) so the app's
# designated requirement — and with it users' Full Disk Access grant — stays the same across
# releases. Override with TIMEFINDER_SIGNING_IDENTITY. The app is not notarized.
set -eu
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> [--publish]}
PUBLISH=${2:-}
IDENTITY=${TIMEFINDER_SIGNING_IDENTITY:-TimeFinder Release Signing}
REPO=${TIMEFINDER_REPO:-lnsp/timefinder}
TAP_REPO=${TIMEFINDER_TAP_REPO:-lnsp/homebrew-tap}
OUT=build/release/$VERSION
ZIP=TimeFinder-$VERSION.zip

fail() { echo "error: $*" >&2; exit 1; }
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "version must look like 1.2.3"
git diff --quiet && git diff --cached --quiet || fail "commit your changes first"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || fail "signing identity '$IDENTITY' not found"
if [ "$PUBLISH" = "--publish" ] && git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  fail "tag v$VERSION already exists"
fi

rm -rf "$OUT"
mkdir -p "$OUT"
echo "Building TimeFinder $VERSION (universal, Release)…"
xcodebuild -project TimeFinder.xcodeproj -scheme TimeFinder -configuration Release \
  -derivedDataPath build/DerivedData-release -destination "generic/platform=macOS" -quiet \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp=none \
  build
APP=build/DerivedData-release/Build/Products/Release/TimeFinder.app

echo "Verifying…"
codesign --verify --strict --deep "$APP"
codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf" || fail "unexpected designated requirement"
codesign -d --entitlements - "$APP" 2>&1 | grep -q "get-task-allow" && fail "release build allows debugging (get-task-allow)"
[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VERSION" ] || fail "version mismatch in Info.plist"
ARCHS=$(lipo -archs "$APP/Contents/MacOS/TimeFinder")
echo "  architectures: $ARCHS"
echo "  $(codesign -d -r- "$APP" 2>&1 | grep designated)"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
SHA=$(shasum -a 256 "$OUT/$ZIP" | cut -d' ' -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/homebrew/timefinder.rb > "$OUT/timefinder.rb"
echo "Built $OUT/$ZIP ($(du -h "$OUT/$ZIP" | cut -f1)), sha256 $SHA"

if [ "$PUBLISH" != "--publish" ]; then
  echo "Dry run. Cask: $OUT/timefinder.rb — rerun with --publish to release."
  exit 0
fi

echo "Publishing v$VERSION…"
git tag -a "v$VERSION" -m "TimeFinder $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$OUT/$ZIP" --repo "$REPO" --title "TimeFinder $VERSION" --generate-notes

TAP=$(mktemp -d)
trap 'rm -rf "$TAP"' EXIT
gh repo clone "$TAP_REPO" "$TAP" -- --quiet
mkdir -p "$TAP/Casks"
cp "$OUT/timefinder.rb" "$TAP/Casks/timefinder.rb"
git -C "$TAP" add Casks/timefinder.rb
git -C "$TAP" commit --quiet -m "timefinder $VERSION"
git -C "$TAP" push --quiet
echo "Released: brew install --cask ${TAP_REPO%%/*}/tap/timefinder"
