#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /private/tmp/cos-mac-recording-checks.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
COS_COMPILE_PROFILE=bounded "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MacRecordingCore.swift" "$ROOT/Tests/MacRecordingChecks.swift" -o "$DIR/checks"
"$DIR/checks"
