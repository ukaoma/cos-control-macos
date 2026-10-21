#!/bin/zsh
# 0.5.333 lens plans: the pure rules, compiled alone (two files, not a full compile), then the wiring pins.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /private/tmp/cos-work-lens-plans.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/WorkLensPlans.swift" "$ROOT/Tests/WorkLensPlansChecks.swift" -o "$OUT/checks"
"$OUT/checks"
/usr/bin/python3 "$ROOT/Tests/work-lens-plans-pins.py" "$ROOT"
