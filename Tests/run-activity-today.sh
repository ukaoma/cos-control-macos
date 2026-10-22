#!/bin/zsh
# Activity Today home (plan v2, 2026-10-21): the predicates, the plan's five pin tests, the tool-name guard, the platform
# table, the finished hour and the cap, the intake split and its midnight move, quiet hours, the Work-run cost guards,
# capability gating and the layout breakpoints, executed against fictional fixture rows (Tests/ActivityTodayChecks.swift).
# Compiled with the models alone, through the shared compile guard. Austin's time zone. Nothing is drawn, clicked or shown.
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-activity-today.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/ActivityTodayChecks.swift" -framework AppKit -o "$BIN"
TZ=America/Chicago "$BIN"
