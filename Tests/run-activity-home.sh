#!/bin/zsh
# 0.5.259 Activity home: which sessions get a desk, the Needs you items and their order, the quiet line, what Next ⌘]
# opens, and the card copy, executed against fixture rows (Tests/ActivityHomeChecks.swift). Compiled with the models
# alone. Austin's time zone, because the fixtures are a Tuesday night there. Nothing is drawn, clicked or shown.
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-activity-home.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/ActivityHomeChecks.swift" -framework AppKit -o "$BIN"
TZ=America/Chicago "$BIN"
