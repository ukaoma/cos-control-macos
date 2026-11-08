#!/bin/zsh
# Native Today subagent fallback: strict optional DTO, list/live precedence and exact summary input rows.
# Pure fictional rows, models only, through the machine-wide compile guard; no helper, UI, store or inference calls.
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp "${TMPDIR:-/tmp}/cos-today-subagents.XXXXXX")"
trap 'rm -f "$BIN"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/TodaySummarySubagentChecks.swift" -framework AppKit -o "$BIN"
TZ=America/Chicago "$BIN"
