#!/bin/zsh
# 0.5.345 Wave A: render Settings, Dictation (the rows Wave A changed) and an edited dictation's card with its next-time
# lines (Tests/DictationParityRender.swift) offscreen, light and dark, at 390 pt, through the real stores with stand-in
# helper bridges: no window is shown, the process never activates, no helper runs, nothing is clicked or typed. The one
# full Sources compile goes through the guard; run it only when nothing else is compiling.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-dictation-parity-render.sh <folder for the PNGs>}"
OUT="${OUT:A}"
DIR="$(mktemp -d /tmp/cos-parity-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/DictationParityRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/parity-render"
HOME_DIR="$DIR/cos-parity-render home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" TMPDIR="$DIR/" "$DIR/parity-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
ls "$OUT"
