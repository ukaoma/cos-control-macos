#!/bin/zsh
# Control's half of the restart lockout. Tests/run-meeting-restart.sh <compiled helper>: the small model compile through
# Tests/compile-guard.sh, then the helper's status and pending-batch scan down to what the disabled buttons read.
set -euo pipefail
ROOT="${0:A:h:h}"
HELPER="${1:?usage: run-meeting-restart.sh <compiled helper>}"
DIR="$(mktemp -d /tmp/cos-meeting-restart.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/KeyLanes.swift" "$ROOT/Sources/Models.swift" "$ROOT/Tests/MeetingRestartChecks.swift" -framework AppKit -o "$DIR/checks"
python3 "$ROOT/Tests/meeting-restart-checks.py" "$HELPER" "$DIR/checks"
