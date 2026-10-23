#!/bin/zsh
# 0.5.337 hardening (the loop and performance audits): the wiring pins (Tests/hardening-337-pins.py), then the rules
# against fictional fixtures (Tests/Hardening337Checks.swift), compiled with the pure sources alone through the shared
# compile guard. Austin's time zone. Nothing is drawn, clicked or shown.
#   COS_HARDENING_LANE=pins|models run-hardening-337.sh   one lane alone (Tests/mutate-hardening-337.py)
set -euo pipefail
ROOT="${0:A:h:h}"
LANE="${COS_HARDENING_LANE:-all}"
BIN="$(mktemp /tmp/cos-hardening-337.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  /usr/bin/python3 "$ROOT/Tests/hardening-337-pins.py" "$ROOT"
fi
if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "$ROOT/Sources/Models.swift" "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/MeetingAskCore.swift" "$ROOT/Sources/WorkLensPlans.swift" \
    "$ROOT/Sources/WorkOrchestrator.swift" "$ROOT/Sources/MacDictationCore.swift" "$ROOT/Tests/Hardening337Checks.swift" -framework AppKit -o "$BIN"
  OUT="$(TZ=America/Chicago "$BIN")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*hardening: }%% checks*}"
  (( COUNT >= 70 )) || { print -u2 "0.5.337 hardening checks ran only $COUNT (expected at least 70)"; exit 1; }
fi
