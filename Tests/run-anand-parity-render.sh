#!/bin/zsh
# Anand parity (D4): the trail row and Meetings on today on a fixture (Tests/AnandParityRender.swift), built like
# Tests/run-activity-sizing.sh: the app's window, never ordered in, a scratch home with no helper.
#   Tests/run-anand-parity-render.sh <folder> 760x560 1119x760
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-anand-parity-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
OUT="${1:A}"; shift
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/AnandParityRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -framework Vision -o "$DIR/anand-parity-render"
HOME_DIR="$DIR/cos-anand-parity-render home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/" 2>/dev/null || true
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" \
  "$DIR/anand-parity-render" "$OUT" "$@" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
