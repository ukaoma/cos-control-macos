#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:-0.1.0}"
BUILD_DIR="$ROOT/.build/release"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/COS Control.app"
ZIP="$DIST_DIR/COS-Control-macOS-arm64-$VERSION.zip"

rm -rf "$BUILD_DIR" "$APP" "$ZIP" "$ZIP.sha256"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST_DIR"

swiftc -swift-version 6 -strict-concurrency=complete \
  "$ROOT/HelperSources/main.swift" \
  -framework Security \
  -o "$APP/Contents/Resources/cos-control-helper"

swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
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
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
/usr/bin/shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo "Built $ZIP"
