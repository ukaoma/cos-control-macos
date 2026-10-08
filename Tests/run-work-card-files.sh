#!/bin/zsh
# 0.5.254 files on a Work card: names, sniffing, refusals, the block in every send, Cursor's cut, the Continue delta,
# cleanup, the manifest under its lock, companions and drop routes. Fixtures are made under a temporary home whose path
# has a space, a dot and a non-ASCII letter. Drops are called with URLs and item providers: nothing is dragged or shown.
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-work-card-files.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/WorkCardFilesChecks.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$BIN"
"$BIN"
