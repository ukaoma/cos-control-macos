#!/bin/zsh
# 0.5.380 (Miles 2026-11-08, server 7.0.5): Summaries per day and the reconnect ask. The pure rules (TodaySummary.Cap,
# TodaySummary.Reconnect, the daily cap line) run in Tests/TodayCapChecks.swift, compiled with Models.swift alone; the wiring
# is pinned by Tests/today-cap-pins.py. Caller must own the shared Swift lane (one full compile machine-wide).
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /tmp/cos-today-cap.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
/usr/bin/python3 "$ROOT/Tests/today-cap-pins.py" "$ROOT"
COS_COMPILE_PROFILE=bounded /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc \
  -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/TodayCapChecks.swift" -framework AppKit -o "$OUT/checks"
"$OUT/checks"
