#!/bin/zsh
# 0.5.343 Build-up, in place, by hand only (never a gate): the real COSBuildUp around stand-ins for three call sites (the
# Meetings list, a Meeting Ask answer, the Today home's Needs you card), frozen at five moments, light and dark, drawn off
# screen to PNGs in <folder> for a side-by-side check against the approved mock. A scratch home: no server, no helper.
# No window is ordered in and nothing is clicked, typed or activated.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-build-up-render.sh <folder for the PNGs> [geometry]}"
OUT="${OUT:A}"
DIR="$(mktemp -d /tmp/cos-build-up-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/BuildUpRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/build-up-render"
HOME_DIR="$DIR/cos-build-up-render home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" "$DIR/build-up-render" "$OUT" ${2:-} 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
