#!/bin/zsh
# Settings hub, by hand only (never a gate): every category, light and dark, at 1280 and 900 wide, the full page, search
# (a match, an old label, no match), the 760 minimum, and the Activity window in the Today and classic frames, drawn off
# screen to PNGs in <folder> for QA against design/settings-hub. A scratch home: no server, no provider. No window is
# ordered in and nothing is clicked, typed or dragged.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-settings-hub-render.sh <folder for the PNGs>}"
OUT="${OUT:A}"
DIR="$(mktemp -d /tmp/cos-hub-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/SettingsHubRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/hub-render"
HOME_DIR="$DIR/cos-hub-render home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" "$DIR/hub-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
# COS_HUB_SPY_DEBUG=1: keep the run's stderr (the scroll-spy's inputs) beside the PNGs.
[[ -n "${COS_HUB_SPY_DEBUG:-}" ]] && cp "$DIR/stderr.log" "$OUT/render-stderr.log"
exit 0
