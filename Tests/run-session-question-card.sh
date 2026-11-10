#!/bin/zsh
# 0.5.388 (D4 item 7): COS Control's question card. The model against X1's contract v1 (Models.swift only), then the
# wiring pins: Control lists without `client`, answers only a held question, never approves or hands back.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-question-card.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/SessionQuestionCardChecks.swift" -framework AppKit -o "$TMP/question-card"
"$TMP/question-card"
/usr/bin/python3 "$ROOT/Tests/session-question-pins.py" "$ROOT"
