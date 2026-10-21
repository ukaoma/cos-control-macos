#!/bin/zsh
# 0.5.333 Work orchestrator: the pure rules, compiled alone (two files, not a full compile), then the wiring pins.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /private/tmp/cos-work-orchestrator.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/WorkOrchestrator.swift" "$ROOT/Tests/WorkOrchestratorChecks.swift" -o "$OUT/checks"
"$OUT/checks"
/usr/bin/python3 "$ROOT/Tests/work-orchestrator-pins.py" "$ROOT"
