#!/bin/zsh
# Activity Today home (plan v2), by hand only (never a gate): the Activity window with the Today home on and fictional
# fixture data, drawn off screen to PNGs in <folder> for a side-by-side check against activity-canvas (Main 1440, Narrow
# 920, Dark, CaughtUp): 1440, 1280, 1100, 1099, 920 and 760 wide, caught up, many running, two tabs with the rail, and
# quiet hours, each dark and light. A scratch home: no server, no provider. No window is ordered in and nothing is clicked,
# typed or dragged.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-activity-home-render.sh <folder for the PNGs>}"
OUT="${OUT:A}"
DIR="$(mktemp -d /tmp/cos-today-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/ActivityTodayRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/today-render"
HOME_DIR="$DIR/cos-today-render home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/"   # the lockup and the provider marks, found beside the binary as in the app bundle
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" "$DIR/today-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
