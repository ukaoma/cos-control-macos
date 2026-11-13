#!/bin/zsh
# 0.5.393 Meetings scroll (Tests/MeetingsScrollCheck.swift): the Activity window on Meetings, built like
# Tests/run-activity-sizing.sh, never ordered in, a scratch home with no helper.
#   Tests/run-meetings-scroll.sh check
#   Tests/run-meetings-scroll.sh render <folder> 760x560 760x590 1119x760
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-meetings-scroll.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/MeetingsScrollCheck.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -framework Vision -o "$DIR/meetings-scroll"
HOME_DIR="$DIR/cos-meetings-scroll home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/" 2>/dev/null || true
ARGS=("$@")
[[ "${1:-}" == render && -n "${2:-}" ]] && ARGS[2]="${2:A}"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" \
  "$DIR/meetings-scroll" "${ARGS[@]}" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
