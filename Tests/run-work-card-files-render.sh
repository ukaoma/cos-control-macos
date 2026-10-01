#!/bin/zsh
# 0.5.254, by hand only (never a gate): the Work views with files on a sample card, drawn off screen to PNGs in <folder>
# for a side-by-side check against design/work-card-files-0.5.254-mock.html. The isolated preview store and a scratch
# home: no server, no provider. No window is ordered in and nothing is clicked, typed or dragged.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-work-card-files-render.sh <folder for the PNGs>}"
DIR="$(mktemp -d /tmp/cos-card-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/WorkCardFilesRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$DIR/card-render"
mkdir -p "$DIR/Fonts" "$DIR/home"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/card-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
