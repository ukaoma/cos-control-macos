#!/bin/zsh
# 0.5.321 (Miles, 2026-10-17): Stop and save a glasses meeting from COS Control. Every compile goes through
# Tests/compile-guard.sh, one at a time.
#   run-g2-meeting-stop.sh                       the gate: the wiring pins (Tests/g2-meeting-stop-pins.py), then the pure
#                                                decisions against LiveTranscript.swift and Models.swift alone
#                                                (Tests/G2MeetingStopChecks.swift)
#   COS_G2_STOP_LANE=pins|models run-g2-meeting-stop.sh   one lane alone (Tests/mutate-g2-meeting-stop.py)
# Fixtures only: no helper, no server, no window.
set -euo pipefail
ROOT="${0:A:h:h}"
LANE="${COS_G2_STOP_LANE:-all}"
DIR="$(mktemp -d /tmp/cos-g2-stop.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home"
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  OUT="$(/usr/bin/python3 "$ROOT/Tests/g2-meeting-stop-pins.py" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*pins: }%% passed*}"
  (( COUNT >= 28 )) || { print -u2 "g2 meeting stop pins ran only $COUNT (expected at least 28)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/Models.swift" \
    "$ROOT/Tests/G2MeetingStopChecks.swift" -framework AppKit -o "$DIR/g2-meeting-stop-checks"
  OUT="$(env CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/g2-meeting-stop-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 54 )) || { print -u2 "g2 meeting stop checks ran only $COUNT (expected at least 54)"; exit 1; }
fi
print "PASS: g2 meeting stop (0.5.321)"
