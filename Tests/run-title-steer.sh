#!/bin/zsh
# 0.5.366 (Miles, 2026-11-03: "go on the title mock"): renaming a live recording from the Meetings recorder (server 6.99.0).
# Every compile goes through Tests/compile-guard.sh, one at a time.
#   run-title-steer.sh                     the gate, in order: the wiring pins (Tests/title-steer-pins.py), then the words, the
#                                          decisions, the calls, the answers, the feed and the store against a stand-in helper,
#                                          compiled with MeetingAskCore.swift, LiveTranscript.swift and Models.swift alone
#                                          (Tests/TitleSteerChecks.swift), then the model and the pane with the whole app compiled
#                                          against a stand-in helper (Tests/TitleSteerRender.swift check)
#   COS_TITLE_STEER_LANE=pins|models|wiring|helper run-title-steer.sh   one lane alone (Tests/mutate-title-steer.py); helper only by name
#   run-title-steer.sh render <dir>        by hand: the mock's states as PNGs, light and dark
# The compiled helper's meeting-title-steer and the file's titleSteer run in Tests/run.sh (Tests/title-steer-helper-checks.py, its
# self-test). Fixtures only: no helper, no server, no active-sessions folder, all text invented. The binaries run with a scratch
# home, never order a window in and never become the active app.
set -euo pipefail
ROOT="${0:A:h:h}"
MODE="${1:-check}"
LANE="${COS_TITLE_STEER_LANE:-all}"
DIR="$(mktemp -d /tmp/cos-title-steer.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home" "$DIR/Fonts" "$DIR/fake"
RUN_ENV=(CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home")
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)

app_binary() {
  cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
  cp "$ROOT/Resources/"*.svg "$DIR/" 2>/dev/null || true
  local SOURCES=("$ROOT"/Sources/*.swift)
  SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/TitleSteerRender.swift" \
    -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Vision -o "$DIR/title-steer-render"
}

# A stand-in helper. Every verb is logged (calls.log) with its arguments (args.log) and its stdin (stdin.log). live-transcript
# answers from live-transcript.json, meeting-title-steer from title-steer-read.json or title-steer-write.json (by --title-stdin),
# and any other verb from <verb>.json, or is refused.
fake_helper() {
  cat > "$DIR/fake/helper" <<'FAKE'
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
echo "$1" >> "$D/calls.log"
echo "$*" >> "$D/args.log"
case " $* " in
  *" --title-stdin "*) cat >> "$D/stdin.log"; printf '\n' >> "$D/stdin.log"; cat "$D/title-steer-write.json"; printf '\n'; exit 0 ;;
esac
if [ "$1" = meeting-title-steer ]; then cat "$D/title-steer-read.json"; printf '\n'; exit 0; fi
if [ "$1" = live-transcript ]; then cat "$D/live-transcript.json"; exit 0; fi
if [ -f "$D/$1.json" ]; then cat "$D/$1.json"; printf '\n'; exit 0; fi
printf '{"ok":false,"message":"the stand-in does not answer %s","details":{}}\n' "$1"
exit 1
FAKE
  chmod +x "$DIR/fake/helper"
}

if [[ "$MODE" == "render" ]]; then
  OUT="${2:?usage: run-title-steer.sh render <folder for the PNGs>}"
  mkdir -p "$OUT"
  app_binary
  fake_helper
  env "${RUN_ENV[@]}" "$DIR/title-steer-render" render "${OUT:A}" "$DIR/fake/helper" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
  exit 0
fi
[[ "$MODE" == "check" ]] || { print -u2 "usage: run-title-steer.sh [check | render <dir>]"; exit 64; }

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  OUT="$(/usr/bin/python3 "$ROOT/Tests/title-steer-pins.py" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*pins: }%% passed*}"
  (( COUNT >= 73 )) || { print -u2 "title steer pins ran only $COUNT (expected at least 73)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library \
    "$ROOT/Sources/MeetingAskCore.swift" "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/Models.swift" \
    "$ROOT/Tests/TitleSteerChecks.swift" -framework AppKit -o "$DIR/title-steer-checks"
  OUT="$(env "${RUN_ENV[@]}" "$DIR/title-steer-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  # A floor on the count: a check that silently stops running must fail this.
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 146 )) || { print -u2 "title steer checks ran only $COUNT (expected at least 146)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "wiring" ]]; then
  app_binary
  fake_helper
  # The last line must be the binary's own: an early exit 0 must never pass for a pass.
  OUT="$(env "${RUN_ENV[@]}" "$DIR/title-steer-render" check "$DIR/fake/helper")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  [[ "$OUT" == *"PASS: title steer wiring checks complete" ]] || { print -u2 "the title steer wiring checks did not finish"; exit 1; }
  COUNT="${${OUT##*wiring checks: }%% passed*}"
  (( COUNT >= 30 )) || { print -u2 "title steer wiring checks ran only $COUNT (expected at least 30)"; exit 1; }
fi

# By hand and for the mutation gate only (Tests/run.sh already builds the helper and runs both): the helper's self-test, which
# carries the verb's grammar and whitelists, then the compiled helper against a loopback fixture.
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
  /usr/bin/python3 "$ROOT/Tests/title-steer-helper-checks.py" "$DIR/cos-control-helper"
fi
print "PASS: title steer (0.5.366)"
