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
chmod 700 "$APP/Contents/MacOS/COS Control" "$APP/Contents/Resources/cos-control-helper"
/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/vtool -show-build "$APP/Contents/MacOS/COS Control" | /usr/bin/grep -q 'minos 14.0'
/usr/bin/vtool -show-build "$APP/Contents/Resources/cos-control-helper" | /usr/bin/grep -q 'minos 14.0'
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGED_ZIP"
/usr/bin/ditto "$APP" "$DIST_APP"
/bin/mv "$STAGED_ZIP" "$ZIP"
/usr/bin/shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo "Built $ZIP"
