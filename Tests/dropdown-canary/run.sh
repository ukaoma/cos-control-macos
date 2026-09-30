#!/bin/zsh
# Builds and runs the dropdown canary: a real MenuBarExtra(.window) app that drives itself (about 10 seconds; a test-tube
# icon shows in the menu bar, its panel opens and closes). Log: the path given, or /tmp/dropdown-canary.log.
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="$(mktemp -d /tmp/dropdown-canary.XXXXXX)/DropdownCanary.app"
LOG="${1:-/tmp/dropdown-canary.log}"
mkdir -p "$OUT/Contents/MacOS"
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DropdownCanary</string>
<key>CFBundleIdentifier</key><string>com.gotcos.dropdowncanary</string>
<key>CFBundleExecutable</key><string>DropdownCanary</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -parse-as-library \
  "$ROOT/Sources/COSBrand.swift" "$ROOT/Tests/dropdown-canary/Shim.swift" "$ROOT/Tests/dropdown-canary/Canary.swift" \
  -framework SwiftUI -framework AppKit -o "$OUT/Contents/MacOS/DropdownCanary"
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true
"$OUT/Contents/MacOS/DropdownCanary" "$LOG" >/dev/null 2>&1 || true
cat "$LOG"
