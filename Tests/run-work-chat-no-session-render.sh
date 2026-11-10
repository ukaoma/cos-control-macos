#!/bin/zsh
# 0.5.386, by hand only (never a gate): Work chat and the Agent workspace on a card with no session, drawn off screen to
# PNGs in <folder>. The real stores against a fake transport and a scratch home: no server, no provider. No window is
# ordered in and nothing is clicked, typed or dragged.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-work-chat-no-session-render.sh <folder for the PNGs>}"
DIR="$(mktemp -d /tmp/cos-no-session-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/WorkChatNoSessionRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$DIR/no-session-render"
mkdir -p "$DIR/Fonts" "$DIR/home"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
COS_WORK_ORCHESTRATION_CANDIDATE=1 CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/no-session-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
