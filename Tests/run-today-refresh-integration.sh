#!/bin/zsh
# Real ControllerModel/HelperClient against a private executable fixture. No live transport or UI.
# Reuses the full AppKit kit in Tests/run.sh; one actual production timeout adds about 19 seconds.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-today-refresh-integration.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -m 700 "$DIR/home"
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/TodayRefreshIntegrationChecks.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/today-refresh-integration"
env HOME="$DIR/home" CFFIXED_USER_HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" \
  COS_MAC_SPEAKER_LIVE=0 COS_MAC_SPEAKER_CALL_PRODUCER=0 \
  "$DIR/today-refresh-integration" "$DIR"
