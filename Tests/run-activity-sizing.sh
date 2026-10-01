#!/bin/zsh
# 0.5.254 resize pass, by hand: Tests/ActivitySizing.swift, the Activity window's size limits for every tab and its
# drawings, built like the app and never ordered in. A scratch home whose path has a space, a dot and a non-ASCII letter:
# Activity's Work store opens its journal and card folder there, never in the real home.
#   Tests/run-activity-sizing.sh measure
#   Tests/run-activity-sizing.sh render <folder> 760x560 1280x900 1800x900
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-activity-sizing.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/ActivitySizing.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/activity-sizing"
HOME_DIR="$DIR/cos-activity-sizing home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
ARGS=("$@")
[[ "${1:-}" == render && -n "${2:-}" ]] && ARGS[2]="${2:A}"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" \
  "$DIR/activity-sizing" "${ARGS[@]}" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
