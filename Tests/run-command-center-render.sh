#!/bin/zsh
# The ⌘K command center, by hand only (never a gate): the Activity window with Today on and the panel open, on fictional
# fixtures, drawn off screen to PNGs in <folder>, at 1200 and 760 wide, light and dark, one per state. A scratch home: no
# server, no provider. No window is ordered in and nothing is clicked, typed or dragged. COS_COMMAND_RENDER_ONLY=a,b names
# the scenes to render.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-command-center-render.sh <folder for the PNGs>}"
OUT="${OUT:A}"
DIR="$(mktemp -d /tmp/cos-command-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/CommandCenterRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/render"
HOME_DIR="$DIR/cos-command-render home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" "$DIR/render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
