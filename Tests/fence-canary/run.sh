#!/bin/bash
# Builds and launches the confirmation canary. Requires a human to click.
# Compiles the REAL Sources/COSConfirm.swift so variant E tests the shipped code.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)/FenceCanary.app"
mkdir -p "$OUT/Contents/MacOS"
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>FenceCanary</string>
<key>CFBundleIdentifier</key><string>com.gotcos.fencecanary</string>
<key>CFBundleExecutable</key><string>FenceCanary</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.2</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
  -parse-as-library \
  "$ROOT/Sources/COSBrand.swift" \
  "$ROOT/Sources/COSConfirm.swift" \
  "$ROOT/Tests/fence-canary/Shim.swift" \
  "$ROOT/Tests/fence-canary/Canary.swift" \
  -framework SwiftUI -framework AppKit \
  -o "$OUT/Contents/MacOS/FenceCanary"
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true
: > "$HOME/.cos-canary/fence-canary.log" 2>/dev/null || true
open "$OUT"
echo "canary running — test-tube icon in the menu bar"
echo "log: ~/.cos-canary/fence-canary.log"
