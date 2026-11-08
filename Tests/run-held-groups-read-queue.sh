#!/bin/zsh
# Injectable held-voice read ordering and response-shape checks. No helper or live source is invoked.
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-held-groups-read.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/HeldGroupsReadQueueChecks.swift" -framework AppKit -o "$BIN"
"$BIN"
