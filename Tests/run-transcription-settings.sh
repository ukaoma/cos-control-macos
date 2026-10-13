#!/bin/zsh
# Transcription switcher (server 6.72.0): the store against a stand-in helper and the contract fixture. One small
# compile, through the guard.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-transcription.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MeetingAskCore.swift" "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/Models.swift" "$ROOT/Tests/TranscriptionSettingsChecks.swift" -framework AppKit -o "$DIR/checks"
"$DIR/checks" "$ROOT/Tests/fixtures/stt-settings-6.72.0.json"
