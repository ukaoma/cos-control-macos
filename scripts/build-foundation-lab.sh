#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${COS_FOUNDATION_DIST_DIR:-$ROOT/dist/control2-foundation}"
APP="${COS_FOUNDATION_APP_DIR:-$HOME/Library/Caches/COS Control Work Preview}/COS Control Foundation Lab.app"
mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
  "$ROOT/HelperSources/main.swift" -framework Security -framework AppKit \
  -o "$APP/Contents/Resources/cos-control-helper"
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/HelperClient.swift" "$ROOT/Sources/ControllerModel.swift" \
  "$ROOT/Sources/COSBrand.swift" "$ROOT/Sources/COSMotion.swift" "$ROOT/Sources/COSConfirm.swift" \
  "$ROOT/Sources/Views.swift" "$ROOT/Sources/ActivityWindow.swift" "$ROOT/Sources/ActivityMeetings.swift" \
  "$ROOT/Sources/COSMarkdownParser.swift" "$ROOT/Sources/COSMarkdown.swift" "$ROOT/Sources/SessionLiveFeed.swift" \
  "$ROOT/Sources/SessionPet.swift" "$ROOT/Sources/Control2Foundation.swift" "$ROOT/Sources/WorkHandoffStore.swift" "$ROOT/Sources/WorkHandoffView.swift" "$ROOT/Sources/WorkReviewStore.swift" "$ROOT/Sources/WorkWorkspaceView.swift" \
  "$ROOT/Tests/Control2FoundationLabApp.swift" -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$APP/Contents/MacOS/COS Control Foundation Lab"
# Share the application's actual brand assets, fonts and supporting resources.
/usr/bin/ditto "$ROOT/Resources" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.gotcos.COSControl.FoundationLab</string>
<key>CFBundleName</key><string>COS Control Work Preview</string>
<key>CFBundleDisplayName</key><string>COS Control Work Preview</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>COS Control Foundation Lab</string>
<key>CFBundleShortVersionString</key><string>0.1.7</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --norsrc --keepParent "$APP" "$OUT/COS-Control-Foundation-Lab.zip"
cp "$ROOT/scripts/start-foundation-lab.command" "$OUT/start-foundation-lab.command"
cp "$ROOT/scripts/start-work-connected.command" "$OUT/start-work-connected.command"
chmod +x "$OUT/start-foundation-lab.command" "$OUT/start-work-connected.command"
(cd "$OUT" && /usr/bin/zip -q -u COS-Control-Foundation-Lab.zip start-foundation-lab.command start-work-connected.command)
cp "$ROOT/scripts/start-work-preview.command" "$OUT/start-work-preview.command"
cp "$ROOT/scripts/start-work-redesign.command" "$OUT/start-work-redesign.command"
chmod +x "$OUT/start-work-preview.command" "$OUT/start-work-redesign.command"
(cd "$OUT" && /usr/bin/zip -q -u COS-Control-Foundation-Lab.zip start-work-preview.command start-work-redesign.command)
echo "$APP"
