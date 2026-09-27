#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-work-handoff-contract.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
# Exercise the shipping types and store; only the production @main is replaced.
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/WorkHandoffTests.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$BIN"
"$BIN"
