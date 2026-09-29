#!/bin/zsh
# 0.5.247 Work tracking checks. Synthetic transport and board; no agent messages, no board writes.
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-work-progress.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/WorkProgressChecks.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$BIN"
"$BIN"
