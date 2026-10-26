#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-usage-checks.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" "$ROOT/Tests/SessionUsageChecks.swift" -o "$TMP/checks"
"$TMP/checks"
