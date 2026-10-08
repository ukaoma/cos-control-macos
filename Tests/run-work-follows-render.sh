#!/bin/zsh
# Next release, by hand only (never a gate): what COS moved on the Work board, drawn off screen to PNGs in <folder>. The
# isolated preview store and a scratch home: no server, no provider. No window is ordered in and nothing is clicked.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-work-follows-render.sh <folder for the PNGs>}"
DIR="$(mktemp -d /tmp/cos-follows-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/WorkFollowsRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$DIR/follows-render"
mkdir -p "$DIR/Fonts" "$DIR/home"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/follows-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
