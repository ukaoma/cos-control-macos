#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:-0.1.0}"
TARGET="arm64-apple-macosx14.0"
BUILD_DIR="$(mktemp -d /tmp/cos-control-release.XXXXXX)"
DIST_DIR="$ROOT/dist"
APP="$BUILD_DIR/COS Control.app"
DIST_APP="$DIST_DIR/COS Control.app"
ZIP="$DIST_DIR/COS-Control-macOS-arm64-$VERSION.zip"
STAGED_ZIP="$BUILD_DIR/COS-Control-macOS-arm64-$VERSION.zip"

trap 'rm -rf "$BUILD_DIR"' EXIT

rm -rf "$DIST_APP" "$ZIP" "$ZIP.sha256"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST_DIR"

swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete \
  "$ROOT/HelperSources/main.swift" \
  -framework Security \
  -o "$APP/Contents/Resources/cos-control-helper"

swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/HelperClient.swift" \
  "$ROOT/Sources/ControllerModel.swift" \
  "$ROOT/Sources/Views.swift" \
  "$ROOT/Sources/COSControlApp.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$APP/Contents/MacOS/COS Control"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod 700 "$APP/Contents/MacOS/COS Control" "$APP/Contents/Resources/cos-control-helper"
/usr/bin/xattr -cr "$APP"
# COS_SIGN_IDENTITY: "Developer ID Application: NAME (TEAMID)" enables notarization-grade signing.
# Unset -> ad-hoc (local/dev only; Gatekeeper will block a downloaded copy).
SIGN_ID="${COS_SIGN_IDENTITY:-}"
if [ -n "$SIGN_ID" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/Resources/cos-control-helper"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/COS Control"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  /usr/bin/codesign --force --deep --sign - "$APP"
fi
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/vtool -show-build "$APP/Contents/MacOS/COS Control" | /usr/bin/grep -q 'minos 14.0'
/usr/bin/vtool -show-build "$APP/Contents/Resources/cos-control-helper" | /usr/bin/grep -q 'minos 14.0'
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGED_ZIP"
# COS_NOTARY_PROFILE: a `xcrun notarytool store-credentials` keychain profile name.
if [ -n "$SIGN_ID" ] && [ -n "${COS_NOTARY_PROFILE:-}" ]; then
  /usr/bin/xcrun notarytool submit "$STAGED_ZIP" --keychain-profile "$COS_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP"
  /usr/bin/xcrun stapler validate "$APP"
  rm -f "$STAGED_ZIP"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGED_ZIP"
fi
/usr/bin/ditto "$APP" "$DIST_APP"
/bin/mv "$STAGED_ZIP" "$ZIP"
/usr/bin/shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo "Built $ZIP"
