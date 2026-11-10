#!/bin/zsh
# 0.5.389 (D4): a turn that ended with the app's next-step box (X1 CONTRACT v1). The model (Models.swift only), then the
# wiring pins: server-gated by the projection keys, Today never sends, the reader sends through its own Continue.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-turn-end-ask.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/TurnEndAskChecks.swift" -framework AppKit -o "$TMP/turn-end-ask"
"$TMP/turn-end-ask"
/usr/bin/python3 "$ROOT/Tests/turn-end-ask-pins.py" "$ROOT"
