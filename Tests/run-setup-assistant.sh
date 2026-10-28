#!/bin/zsh
# Ask COS setup and repair assistant (2026-10-27): the wiring pins (Tests/setup-assistant-pins.py), then the engine's rules
# executed against fictional fixtures (Tests/SetupAssistantChecks.swift): ranking and the cap of four, the restart gates,
# the ownership conflict, the server-down and all-clear states, every knowledge-base entry against its phrases, the
# anchor case, the confirm copy and the troubleshoot prompt. Compiled with Sources/SetupAssistant.swift alone, through the
# shared compile guard. Nothing is drawn, run, opened or sent. Hand-run: Tests/mutate-setup-assistant.py (the mutation lane).
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-setup-assistant.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
/usr/bin/python3 "$ROOT/Tests/setup-assistant-pins.py" "$ROOT"
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/SetupAssistant.swift" "$ROOT/Tests/SetupAssistantChecks.swift" -o "$BIN"
"$BIN"
