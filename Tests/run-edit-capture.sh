#!/bin/zsh
# 0.5.344 Capture every correction (plan r2): the wiring pins (Tests/edit-capture-pins.py, which proves each pin can fail
# with in-memory mutants), then the watch loop and its rules against fictional fixtures (Tests/EditCaptureChecks.swift:
# a fake field and a fake clock run the real loop), compiled with Sources/MacDictationCore.swift alone through the shared
# compile guard. Nothing is drawn, clicked, shown, posted or activated.
#   COS_EDIT_CAPTURE_LANE=pins|checks run-edit-capture.sh   one lane alone
# Hand-run: Tests/mutate-edit-capture.py (the mutation lane, serial, green baseline first).
set -euo pipefail
ROOT="${0:A:h:h}"
LANE="${COS_EDIT_CAPTURE_LANE:-all}"
BIN="$(mktemp /tmp/cos-edit-capture.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  /usr/bin/python3 "$ROOT/Tests/edit-capture-pins.py" "$ROOT"
fi
if [[ "$LANE" == "all" || "$LANE" == "checks" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "$ROOT/Sources/MacDictationCore.swift" "$ROOT/Tests/EditCaptureChecks.swift" -o "$BIN"
  OUT="$("$BIN")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*edit capture: }%% checks*}"
  (( COUNT >= 90 )) || { print -u2 "0.5.344 edit capture checks ran only $COUNT (expected at least 90)"; exit 1; }
fi
