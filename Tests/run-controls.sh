#!/bin/zsh
# 0.5.251 GOTCOS controls, executed: the shipped components in a window ordered in far off screen, driven by clicks and
# keys posted in-process; pure rules; rendered pixels. Fonts sit beside the binary, where COSType looks for them.
# 0.5.253: labels (the icon in the middle of one and two lines) and the real menu-bar panel rendered off screen
# (Tests/PanelLabelsRender.swift). The binary carries an Info.plist with this build's version, so the panel's version stamp
# reads as it does in the app, and it runs with a scratch home, so the panel's own loads find no helper and never reach
# the COS server. COS_PANEL_RENDER_OUT, when set, is where the panel's PNGs go.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-controls-contract.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
# The first release heading; an "## Unreleased" entry above it is notes for the next build.
VERSION="$(sed -n 's/^## \([0-9][0-9.]*\) (build [0-9]*).*/\1/p' "$ROOT/CHANGELOG.md" | head -1)"
[[ -n "$VERSION" ]] || { print -u2 "run-controls: no release heading in CHANGELOG.md"; exit 1 }
cat > "$DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.gotcos.control.controls-contract</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
</dict></plist>
PLIST
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/PanelLabelsRender.swift" "$ROOT/Tests/ControlsContract.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Vision \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist" \
  -o "$DIR/controls-contract"
mkdir -p "$DIR/Fonts" "$DIR/home"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
# SwiftUI logs a font-weight notice per custom font it resolves; show the process's stderr only when it fails.
if ! CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" "$DIR/controls-contract" 2>"$DIR/stderr.log"; then
  cat "$DIR/stderr.log" >&2
  exit 1
fi
