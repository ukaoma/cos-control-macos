#!/bin/zsh
# Render the Record on Mac panel after Stop (Tests/QuickSaveRender.swift) offscreen, light and dark, at 390 pt, through
# the real store and panel with a stand-in helper bridge and a fixture spool in a scratch folder: no window is shown, no
# helper runs, nothing is clicked. One full app compile through the guard; run it only when nothing else is compiling.
#   run-quick-save-render.sh <folder for the PNGs>            0.5.351 quick save (-D QUICK_SAVE)
#   QUICK_SAVE_SOURCES=<tree> run-quick-save-render.sh <dir> base   the canary: the same harness on another tree's Sources
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-quick-save-render.sh <folder for the PNGs> [base]}"
OUT="${OUT:A}"
MODE="${2:-quick}"
SRC="${QUICK_SAVE_SOURCES:-$ROOT}"
DIR="$(mktemp -d /tmp/cos-quick-save-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$SRC"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
FLAGS=()
[[ "$MODE" == "base" ]] || FLAGS=(-D QUICK_SAVE)
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${FLAGS[@]}" "${SOURCES[@]}" "$ROOT/Tests/QuickSaveRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/quick-save-render"
HOME_DIR="$DIR/cos-quick-save-render home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$SRC/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$SRC/Resources/"*.svg "$DIR/"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" TMPDIR="$DIR/" "$DIR/quick-save-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
