#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-meeting-ask.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MeetingAskCore.swift" "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/Models.swift" "$ROOT/Tests/MeetingAskChecks.swift" -framework AppKit -o "$DIR/checks"
"$DIR/checks"
