#!/bin/zsh
# Headless Work contract: private fixture only, no desktop, provider dispatch or real journal.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-work-roundtrip-checks.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
if [[ $# == 1 ]]; then
  HELPER="$1"
else
  HELPER="$TMP/cos-control-helper"
  COS_COMPILE_PROFILE=bounded /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
    -framework Security -framework AppKit -o "$HELPER"
fi
/usr/bin/python3 "$ROOT/Tests/work-roundtrip-helper-checks.py" "$HELPER"
# 0.5.312: Connections meter (pure parsers, pins, and the helper verb against this same helper).
"$ROOT/Tests/run-work-session-meter.sh" "$HELPER"
