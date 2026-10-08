#!/bin/bash
# Release-machine only. Customers download the resulting signed, stapled bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=1.9.1
COMMIT=f049fff95a089aa9969deb009cdd4892b3e74916
SOURCE="${COS_WHISPER_SOURCE:-/tmp/cos-whisper-1.9.1-source}"
BUILD="${COS_WHISPER_BUILD:-/tmp/cos-whisper-1.9.1-build}"
OUT="${COS_WHISPER_DIST:-$ROOT/dist/whisper-runtime}"
IDENTITY="${COS_SIGN_IDENTITY:-Developer ID Application: Miles Ukaoma (NV3X46LLCR)}"
PROFILE="${COS_NOTARY_PROFILE:-cos-control-notary}"
[[ "$IDENTITY" == 'Developer ID Application:'* ]] || exit 64
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$COMMIT" ]] || exit 65
[[ -z "$(git -C "$SOURCE" status --porcelain)" ]] || exit 65
mkdir -p "$OUT"
ZIP="$OUT/cos-whisper-runtime-$VERSION-arm64-r1.zip"
[[ ! -e "$ZIP" ]] || { echo 'Refusing to overwrite a runtime archive'; exit 65; }
cmake -S "$SOURCE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_CURL=OFF
cmake --build "$BUILD" --config Release --target whisper-server whisper-cli -j 6
STAGE="$(mktemp -d /tmp/cos-whisper-package.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/COS Whisper Runtime.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SOURCE/LICENSE" "$APP/Contents/Resources/whisper-LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.gotcos.whisper-runtime</string><key>CFBundleName</key><string>COS Whisper Runtime</string><key>CFBundleExecutable</key><string>whisper-server</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.9.1</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/></dict></plist>
PLIST
for binary in whisper-server whisper-cli; do
  cp "$BUILD/bin/$binary" "$APP/Contents/MacOS/$binary"
  # Fail on any non-system dynamic dependency; don't ship a Homebrew-linked binary.
  otool -L "$APP/Contents/MacOS/$binary" | tail -n +2 | awk '{print $1}' | while read -r dependency; do
    case "$dependency" in /System/Library/*|/usr/lib/*) ;; *) echo "External dependency: $dependency"; exit 66 ;; esac
  done
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/$binary"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP" "$STAGE/submit.zip"
xcrun notarytool submit "$STAGE/submit.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/notarization.json"
python3 - "$OUT/notarization.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['status']=='Accepted'
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
ditto -x -k "$ZIP" "$STAGE/extracted"
FINAL="$STAGE/extracted/COS Whisper Runtime.app"
codesign --verify --deep --strict "$FINAL"
xcrun stapler validate "$FINAL"
spctl --assess --type execute --verbose=2 "$FINAL"
shasum -a 256 "$ZIP" > "$ZIP.sha256"
