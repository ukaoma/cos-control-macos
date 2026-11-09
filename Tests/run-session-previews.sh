#!/bin/zsh
# 0.5.380 (preview engine phase 1, plan item 6): the Sessions pane's file and image cards. The store and its rules
# (Sources/SessionPreviews.swift) run in Tests/SessionPreviewsChecks.swift, compiled with Models.swift alone, against a
# stand-in helper under a private /tmp home: no server, no window, no Quick Look panel. The wiring is pinned by
# Tests/session-previews-pins.py. Caller must own the shared Swift lane (one full compile machine-wide).
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /tmp/cos-session-previews.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/home"
/usr/bin/python3 "$ROOT/Tests/session-previews-pins.py" "$ROOT"
COS_COMPILE_PROFILE=bounded /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc \
  -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/SessionPreviews.swift" "$ROOT/Sources/SessionReplyLinks.swift" "$ROOT/Tests/SessionPreviewsChecks.swift" \
  -framework AppKit -o "$OUT/checks"
CFFIXED_USER_HOME="$OUT/home" COS_CONTROL_TEST_HOME="$OUT/home" "$OUT/checks"
