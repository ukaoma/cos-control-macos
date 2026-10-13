#!/bin/zsh
# Home city (server 6.71.13): the store against a stand-in helper. One small compile, through the guard.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-home-area.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MeetingAskCore.swift" "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/Models.swift" "$ROOT/Tests/HomeAreaChecks.swift" -framework AppKit -o "$DIR/checks"
"$DIR/checks"
