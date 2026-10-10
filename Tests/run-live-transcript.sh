#!/bin/zsh
# 0.5.278 (Miles, 2026-10-10): the live meeting transcript in Meetings. Every compile goes through Tests/compile-guard.sh,
# one at a time.
#   run-live-transcript.sh                     the gate, in order: the wiring pins (Tests/live-transcript-pins.py), the pure
#                                              reducer and status fields against LiveTranscript.swift and Models.swift alone
#                                              (Tests/LiveTranscriptChecks.swift), the compiled helper against a 6.67-shape
#                                              fixture (Tests/live-transcript-helper-checks.py), then the model with the whole
#                                              app compiled against a stand-in helper (Tests/LiveTranscriptRender.swift check)
#   COS_LIVE_TRANSCRIPT_LANE=pins|models|helper|wiring run-live-transcript.sh   one lane alone (Tests/mutate-live-transcript.py)
#   run-live-transcript.sh render <dir>        by hand: PNGs, light and dark
# Fixtures only: the real active-sessions folder is never read, the server never reached, all text invented. The binaries
# run with a scratch home, never order a window in and never become the active app.
set -euo pipefail
ROOT="${0:A:h:h}"
MODE="${1:-check}"
LANE="${COS_LIVE_TRANSCRIPT_LANE:-all}"
DIR="$(mktemp -d /tmp/cos-live-transcript.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home" "$DIR/Fonts" "$DIR/fake"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/" 2>/dev/null || true
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
RUN_ENV=(CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home")
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)

app_binary() {
  "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/LiveTranscriptRender.swift" \
    -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$DIR/live-transcript-render"
}

# A stand-in helper. Every verb is logged (calls.log) with its arguments (args.log). live-transcript answers by
# live-mode: normal (live-transcript.json), hold (waits for `release`, consumed), secret (an invalid answer with text
# in it), refuse (a reason code), ended (the file gone). While one runs it holds the `inflight` folder; a second one
# starting meanwhile writes overlap.log. Any other verb answers <verb>.json, or is refused.
fake_helper() {
  cat > "$DIR/fake/helper" <<'FAKE'
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
echo "$1" >> "$D/calls.log"
echo "$*" >> "$D/args.log"
if [ "$1" = live-transcript ]; then
  if ! mkdir "$D/inflight" 2>/dev/null; then echo overlap >> "$D/overlap.log"; fi
  mode="$(cat "$D/live-mode" 2>/dev/null)"
  case "$mode" in
    hold) i=0; while [ ! -f "$D/release" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done; rm -f "$D/release"
          cat "$D/live-transcript.json" ;;
    secret) printf 'not json: SECRET transcript words\n' ;;
    refuse) printf '{"ok":false,"message":"Live transcript unavailable (parse_failed)","details":{"reason":"parse_failed"}}\n'; rmdir "$D/inflight"; exit 1 ;;
    ended) printf '{"ok":true,"message":"Live transcript","details":{"dataDir":"/tmp/cos-live-fixture-data","sessions":[],"read":{"sessionId":"meeting_1791635349988_fx67ab","ended":true,"unchanged":false}}}\n' ;;
    *) cat "$D/live-transcript.json" ;;
  esac
  rmdir "$D/inflight" 2>/dev/null
  exit 0
fi
if [ -f "$D/$1.json" ]; then cat "$D/$1.json"; printf '\n'; exit 0; fi
printf '{"ok":false,"message":"the stand-in does not answer %s","details":{}}\n' "$1"
exit 1
FAKE
  chmod +x "$DIR/fake/helper"
}

if [[ "$MODE" == "render" ]]; then
  OUT="${2:?usage: run-live-transcript.sh render <folder for the PNGs>}"
  app_binary
  fake_helper
  env "${RUN_ENV[@]}" "$DIR/live-transcript-render" render "${OUT:A}" "$DIR/fake/helper" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
  exit 0
fi
[[ "$MODE" == "check" ]] || { print -u2 "usage: run-live-transcript.sh [check | render <dir>]"; exit 64; }

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  OUT="$(/usr/bin/python3 "$ROOT/Tests/live-transcript-pins.py" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*pins: }%% passed*}"
  (( COUNT >= 96 )) || { print -u2 "live transcript pins ran only $COUNT (expected at least 96)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/Models.swift" \
    "$ROOT/Tests/LiveTranscriptChecks.swift" -framework AppKit -o "$DIR/live-transcript-checks"
  OUT="$(env "${RUN_ENV[@]}" "$DIR/live-transcript-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  # A floor on the count: a check that silently stops running must fail this.
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 64 )) || { print -u2 "live transcript checks ran only $COUNT (expected at least 64)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "helper" ]]; then
  "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" \
    -framework Security -framework AppKit -o "$DIR/cos-control-helper"
  # The helper's own self-test carries the path grammar, the containment, the fixture parse and the cursor rules.
  OUT="$(env COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/cos-control-helper" self-test 2>"$DIR/self-test.err")" || { print -r -- "$OUT"; cat "$DIR/self-test.err"; exit 1; }
  /usr/bin/python3 -c 'import json,sys; v=json.loads(sys.argv[1]); sys.exit(0 if v.get("ok") and v["details"]["tests"] >= 819 else "helper self-test: " + str(v)[:600])' "$OUT"
  print -r -- "helper self-test: ${OUT[1,120]}"
  OUT="$(/usr/bin/python3 "$ROOT/Tests/live-transcript-helper-checks.py" "$DIR/cos-control-helper")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 34 )) || { print -u2 "live transcript helper checks ran only $COUNT (expected at least 34)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "wiring" ]]; then
  app_binary
  fake_helper
  # The last line must be the binary's own: an early exit 0 must never pass for a pass.
  OUT="$(env "${RUN_ENV[@]}" "$DIR/live-transcript-render" check "$DIR/fake/helper")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  [[ "$OUT" == *"PASS: live transcript wiring checks complete" ]] || { print -u2 "the live transcript wiring checks did not finish"; exit 1; }
  COUNT="${${OUT##*wiring checks: }%% passed*}"
  (( COUNT >= 30 )) || { print -u2 "live transcript wiring checks ran only $COUNT (expected at least 30)"; exit 1; }
fi
