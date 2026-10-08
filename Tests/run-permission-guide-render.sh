#!/bin/zsh
# Render the permission guide (Tests/PermissionGuideRender.swift) offscreen, light and dark, from fixture facts: no
# window is shown, nothing reads TCC or opens System Settings. The one full app compile goes through the guard.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-permission-guide-render.sh <folder for the PNGs>}"
OUT="${OUT:A}"
DIR="$(mktemp -d /tmp/cos-home-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/PermissionGuideRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/permission-render"
HOME_DIR="$DIR/cos-home-render home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" "$DIR/permission-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
