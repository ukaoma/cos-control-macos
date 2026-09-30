#!/bin/zsh
# Builds and runs the dropdown canary. By default it runs off screen: it can never become the active app, adds no status
# item and puts nothing on any screen (frames of the open list, and the stock-control calibration). Safe while someone
# uses the Mac. COS_DESKTOP_CANARY=1 also drives a real MenuBarExtra(.window) and a normal window: it shows a test-tube
# status item and its panel, opens a small window on screen and takes the keyboard focus for about 30 seconds, so it
# must only be run with the Mac's owner at the keyboard expecting it. No gate sets it, and it is not part of run.sh.
# Exit 0 only if every check held.
#   Tests/dropdown-canary/run.sh [log path] [frames dir]
# Log: the path given, or /tmp/dropdown-canary.log. With a frames dir it saves real frames of the open list there.
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="$(mktemp -d /tmp/dropdown-canary.XXXXXX)/DropdownCanary.app"
LOG="${1:-/tmp/dropdown-canary.log}"
FRAMES="${2:-}"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/Fonts"
cp "$ROOT/Resources/Fonts/"*.ttf "$OUT/Contents/Resources/Fonts/"
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
STATUS=0
if [[ -n "$FRAMES" ]]; then
  "$OUT/Contents/MacOS/DropdownCanary" "$LOG" "$FRAMES" >/dev/null 2>&1 || STATUS=$?
else
  "$OUT/Contents/MacOS/DropdownCanary" "$LOG" >/dev/null 2>&1 || STATUS=$?
fi
cat "$LOG"
exit $STATUS
