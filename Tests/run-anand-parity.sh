#!/bin/zsh
# Anand parity (D4, 2026-11-12): the Mac's words for Control Web 7.0.30's settled items (Tests/AnandParityChecks.swift, with the
# models alone, through the shared compile guard), then the wiring pins (Tests/anand-parity-pins.py).
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-anand-parity.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/AnandParityChecks.swift" -framework AppKit -o "$BIN"
TZ=America/Chicago "$BIN"
/usr/bin/python3 "$ROOT/Tests/anand-parity-pins.py" "$ROOT"
