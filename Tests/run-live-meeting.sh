#!/bin/zsh
# 0.5.336 (server 6.86.0): the live meeting view. Every compile goes through Tests/compile-guard.sh, one at a time.
#   run-live-meeting.sh                     the gate, in order: the wiring pins (Tests/live-meeting-pins.py), then the pure
#                                           rules (capability gating, counts, anchoring, the strip, the title, the audiogram
#                                           ring, the preview rate cap, the grey line) against LiveTranscript.swift and
#                                           Models.swift alone (Tests/LiveMeetingChecks.swift), then the compiled helper's
#                                           live-provisional and Mac preview against loopback fixtures
#   COS_LIVE_MEETING_LANE=pins|models|helper run-live-meeting.sh   one lane alone (Tests/mutate-live-meeting.py)
# Fixtures only: no server, no audio device, invented words.
set -euo pipefail
ROOT="${0:A:h:h}"
LANE="${COS_LIVE_MEETING_LANE:-all}"
DIR="$(mktemp -d /tmp/cos-live-meeting.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home"
RUN_ENV=(CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home")
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  OUT="$(/usr/bin/python3 "$ROOT/Tests/live-meeting-pins.py" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*pins: }%% passed*}"
  (( COUNT >= 280 )) || { print -u2 "live meeting pins ran only $COUNT (expected at least 280)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/Models.swift" \
    "$ROOT/Tests/LiveMeetingChecks.swift" -framework AppKit -o "$DIR/live-meeting-checks"
  OUT="$(env "${RUN_ENV[@]}" "$DIR/live-meeting-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  # A floor on the count: a check that silently stops running must fail this.
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 82 )) || { print -u2 "live meeting checks ran only $COUNT (expected at least 82)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "helper" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
    -framework Security -framework AppKit -o "$DIR/cos-control-helper"
  OUT="$(env COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/cos-control-helper" self-test 2>"$DIR/self-test.err")" || { print -r -- "$OUT"; cat "$DIR/self-test.err"; exit 1; }
  FLOOR="$(/usr/bin/sed -n 's/^if count < \([0-9][0-9]*\):$/\1/p' "$ROOT/Tests/run.sh" | /usr/bin/head -1)"
  [[ -n "$FLOOR" ]] || { print -u2 "could not read the helper self-test floor from Tests/run.sh"; exit 1; }
  /usr/bin/python3 -c 'import json,sys; v=json.loads(sys.argv[1]); f=int(sys.argv[2]); sys.exit(0 if v.get("ok") and v["details"]["tests"] >= f else "helper self-test below floor %d: " % f + str(v)[:600])' "$OUT" "$FLOOR"
  print -r -- "helper self-test: ${OUT[1,120]}"
  for check in live-meeting-helper-checks mac-recording-helper-checks cue-verdicts-helper-checks; do
    OUT="$(/usr/bin/python3 "$ROOT/Tests/$check.py" "$DIR/cos-control-helper")" || { print -r -- "$OUT"; exit 1; }
    print -r -- "$OUT"
  done
  COUNT="$(/usr/bin/python3 "$ROOT/Tests/live-meeting-helper-checks.py" "$DIR/cos-control-helper")"
  COUNT="${${COUNT##*checks: }%% passed*}"
  (( COUNT >= 19 )) || { print -u2 "live meeting helper checks ran only $COUNT (expected at least 19)"; exit 1; }
fi
print "PASS: live meeting (0.5.336)"
