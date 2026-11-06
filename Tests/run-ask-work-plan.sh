#!/bin/zsh
# Real-store fixture with a closed fake helper transport; no live server, providers, or helper process.
# Compilation uses the shared guarded kit. Run only when the caller owns the Swift compile slot.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /tmp/cos-ask-work-plan.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
COS_COMPILE_PROFILE=bounded /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc \
  -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/AskWorkPlanChecks.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$OUT/checks"
mkdir -p "$OUT/home"
CFFIXED_USER_HOME="$OUT/home" COS_CONTROL_TEST_HOME="$OUT/home" "$OUT/checks"
