#!/bin/zsh
# 0.5.327 (Miles, 2026-10-19): rating live cues (server 6.79.0). Every compile goes through Tests/compile-guard.sh, one at a
# time.
#   run-cue-verdicts.sh                           the gate: the wiring pins (Tests/cue-verdicts-pins.py), then the words, the
#                                                 keys, the 15-second floor and the store against a stand-in helper, compiled
#                                                 with MeetingAskCore.swift, LiveTranscript.swift and Models.swift alone
#                                                 (Tests/CueVerdictsChecks.swift), then the Memories page's two entries
#                                                 (Tests/MemoriesCuesCanary.cjs)
#   COS_CUE_VERDICTS_LANE=pins|models|page|helper run-cue-verdicts.sh   one lane alone (Tests/mutate-cue-verdicts.py); helper only by name
#   run-cue-verdicts.sh render <dir>              by hand: the cue review and the Cues view, light and dark, read by Vision
# The compiled helper's live-cues-history and live-cues-rate run in Tests/run.sh (Tests/cue-verdicts-helper-checks.py, its
# self-test). Fixtures only: no helper, no server, and the render never orders a window in.
set -euo pipefail
ROOT="${0:A:h:h}"
MODE="${1:-check}"
LANE="${COS_CUE_VERDICTS_LANE:-all}"
DIR="$(mktemp -d /tmp/cos-cue-verdicts.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home"
RUN_ENV=(CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home")
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)

if [[ "$MODE" == "render" ]]; then
  OUT="${2:?usage: run-cue-verdicts.sh render <folder for the PNGs>}"
  mkdir -p "$OUT"
  SOURCES=("$ROOT"/Sources/*.swift)
  SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/CueVerdictsRender.swift" \
    -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Vision -o "$DIR/cue-verdicts-render"
  env "${RUN_ENV[@]}" "$DIR/cue-verdicts-render" "${OUT:A}"
  exit 0
fi
[[ "$MODE" == "check" ]] || { print -u2 "usage: run-cue-verdicts.sh [check | render <dir>]"; exit 64; }

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  OUT="$(/usr/bin/python3 "$ROOT/Tests/cue-verdicts-pins.py" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*pins: }%% passed*}"
  (( COUNT >= 73 )) || { print -u2 "cue verdicts pins ran only $COUNT (expected at least 73)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library \
    "$ROOT/Sources/MeetingAskCore.swift" "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/Models.swift" \
    "$ROOT/Tests/CueVerdictsChecks.swift" -framework AppKit -o "$DIR/cue-verdicts-checks"
  OUT="$(env "${RUN_ENV[@]}" "$DIR/cue-verdicts-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 156 )) || { print -u2 "cue verdicts checks ran only $COUNT (expected at least 156)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "page" ]]; then
  OUT="$(node "$ROOT/Tests/MemoriesCuesCanary.cjs")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*canary: }%% passed*}"
  (( COUNT >= 17 )) || { print -u2 "memories cues canary ran only $COUNT (expected at least 17)"; exit 1; }
fi
# By hand and for the mutation gate only (Tests/run.sh already builds the helper and runs both): the helper's self-test,
# which carries the two verbs' grammar and whitelists, then the compiled helper against a loopback fixture.
if [[ "$LANE" == "helper" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
    -framework Security -framework AppKit -o "$DIR/cos-control-helper"
  OUT="$(env COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/cos-control-helper" self-test 2>"$DIR/self-test.err")" || true
  FLOOR="$(/usr/bin/sed -n 's/^if count < \([0-9][0-9]*\):$/\1/p' "$ROOT/Tests/run.sh" | /usr/bin/head -1)"
  /usr/bin/python3 -c 'import json,sys
try: v=json.loads(sys.argv[1])
except ValueError: sys.exit("helper self-test FAILED: no JSON")
f=int(sys.argv[2])
if not v.get("ok"): sys.exit("helper self-test FAILED: " + str(v.get("message"))[:600])
if v["details"]["tests"] < f: sys.exit("helper self-test FAILED: below floor %d" % f)
print("helper self-test: %d passed" % v["details"]["tests"])' "$OUT" "$FLOOR"
  /usr/bin/python3 "$ROOT/Tests/cue-verdicts-helper-checks.py" "$DIR/cos-control-helper"
fi
print "PASS: cue verdicts (0.5.327)"
