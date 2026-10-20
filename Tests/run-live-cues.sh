#!/bin/zsh
# 0.5.322 (Miles, 2026-10-17): the Live cues switch in Settings (server 6.76.2). Every compile goes through
# Tests/compile-guard.sh, one at a time.
#   run-live-cues.sh                         the gate: the wiring pins (Tests/live-cues-pins.py), then the words and the
#                                            store against a stand-in helper, compiled with MeetingAskCore.swift,
#                                            LiveTranscript.swift and Models.swift alone (Tests/LiveCuesChecks.swift)
#   COS_LIVE_CUES_LANE=pins|models|helper run-live-cues.sh   one lane alone (Tests/mutate-live-cues.py); helper only by name
#   run-live-cues.sh render <dir>            by hand: the Meeting assistant card at 390 pt, every state, light and dark
# The compiled helper's live-cues-settings runs in Tests/run.sh (Tests/live-cues-helper-checks.py, its self-test).
# Fixtures only: no helper, no server, and the render never orders a window in.
set -euo pipefail
ROOT="${0:A:h:h}"
MODE="${1:-check}"
LANE="${COS_LIVE_CUES_LANE:-all}"
DIR="$(mktemp -d /tmp/cos-live-cues.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home"
RUN_ENV=(CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home")
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)

if [[ "$MODE" == "render" ]]; then
  OUT="${2:?usage: run-live-cues.sh render <folder for the PNGs>}"
  mkdir -p "$OUT"
  SOURCES=("$ROOT"/Sources/*.swift)
  SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
  mkdir -p "$DIR/Fonts"; cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/LiveCuesRender.swift" \
    -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Vision -o "$DIR/live-cues-render"
  env "${RUN_ENV[@]}" "$DIR/live-cues-render" "${OUT:A}"
  exit 0
fi
[[ "$MODE" == "check" ]] || { print -u2 "usage: run-live-cues.sh [check | render <dir>]"; exit 64; }

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  OUT="$(/usr/bin/python3 "$ROOT/Tests/live-cues-pins.py" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*pins: }%% passed*}"
  (( COUNT >= 80 )) || { print -u2 "live cues pins ran only $COUNT (expected at least 80)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library \
    "$ROOT/Sources/MeetingAskCore.swift" "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/Models.swift" \
    "$ROOT/Tests/LiveCuesChecks.swift" -framework AppKit -o "$DIR/live-cues-checks"
  OUT="$(env "${RUN_ENV[@]}" "$DIR/live-cues-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 153 )) || { print -u2 "live cues checks ran only $COUNT (expected at least 153)"; exit 1; }
fi
# By hand and for the mutation gate only (Tests/run.sh already builds the helper and runs both): the helper's self-test,
# which carries the --set grammar and the key whitelist, then the compiled helper against a loopback fixture.
if [[ "$LANE" == "helper" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
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
  /usr/bin/python3 "$ROOT/Tests/live-cues-helper-checks.py" "$DIR/cos-control-helper"
fi
print "PASS: live cues (0.5.322)"
