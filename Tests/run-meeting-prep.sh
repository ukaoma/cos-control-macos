#!/bin/zsh
# No live helper, provider, capture or UI. Caller must own the shared Swift lane.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /tmp/cos-meeting-prep.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/home"
COS_COMPILE_PROFILE=bounded /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc \
  -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MeetingPrep.swift" "$ROOT/Tests/MeetingPrepChecks.swift" -o "$OUT/state"
CFFIXED_USER_HOME="$OUT/home" COS_CONTROL_TEST_HOME="$OUT/home" "$OUT/state"
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
COS_COMPILE_PROFILE=bounded /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc \
  -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/MeetingPrepStoreChecks.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$OUT/store"
CFFIXED_USER_HOME="$OUT/home" COS_CONTROL_TEST_HOME="$OUT/home" "$OUT/store"
