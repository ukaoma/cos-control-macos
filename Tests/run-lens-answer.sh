#!/bin/zsh
# 0.5.380 (Miles 2026-11-08, server 7.0.5 parity): the Messages pane structures a COS answer's inline numbered lists the way
# Control Web does. The rules (Sources/LensAnswerStructure.swift) run in Tests/LensAnswerStructureChecks.swift, compiled with
# that file alone, on the web's cases; Tests/lens-answer-parity-pins.py compares them with the server's app.js and test, and
# pins where the pane applies it. Caller must own the shared Swift lane (one full compile machine-wide).
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /tmp/cos-lens-answer.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
/usr/bin/python3 "$ROOT/Tests/lens-answer-parity-pins.py" "$ROOT"
COS_COMPILE_PROFILE=bounded /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc \
  -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/LensAnswerStructure.swift" "$ROOT/Tests/LensAnswerStructureChecks.swift" -o "$OUT/checks"
"$OUT/checks"
