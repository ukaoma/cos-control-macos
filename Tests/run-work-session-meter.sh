#!/bin/zsh
# 0.5.312 Work → Connections meter: the shared pure parsers against fixtures, the wiring pins, and (given a built
# helper) the bounded `work-session-meter` verb. One small two-file compile, through compile-guard.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-work-session-meter.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
COS_COMPILE_PROFILE=bounded "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/WorkSessionLinks.swift" "$ROOT/Tests/WorkSessionMeterChecks.swift" -o "$TMP/checks"
"$TMP/checks" "$ROOT"
/usr/bin/python3 "$ROOT/Tests/work-session-meter-pins.py" "$ROOT"
if [[ $# == 1 ]]; then /usr/bin/python3 "$ROOT/Tests/work-session-meter-helper-checks.py" "$1"; fi
