#!/bin/zsh
# 0.5.371 Drop it (server Drop it P1): the pinned COS chat in Messages, its composer, History, ⌘K's Drop it row and the Settings
# switch. Every compile goes through Tests/compile-guard.sh, one at a time.
#   run-drop-it.sh                       the gate, in order: the wiring pins (Tests/drop-it-pins.py), then the words, replies, calls,
#                                        layout and store against a stand-in helper, compiled with DropIt.swift and Models.swift
#                                        alone (Tests/DropItChecks.swift), then the model, ⌘K and Settings with the whole app compiled
#                                        (Tests/DropItRender.swift check)
#   COS_DROP_IT_LANE=pins|models|wiring|helper run-drop-it.sh   one lane alone (Tests/mutate-drop-it.py); helper only by name
#   run-drop-it.sh render <dir>          by hand: the mock's states as PNGs, light and dark
# The compiled helper's drop-it verb runs in Tests/run.sh (Tests/drop-it-helper-checks.py, and its self-test). Fixtures only: no
# helper, no server, all words invented. The binaries run with a scratch home, never order a window in and never become active.
set -euo pipefail
ROOT="${0:A:h:h}"
MODE="${1:-check}"
LANE="${COS_DROP_IT_LANE:-all}"
DIR="$(mktemp -d /tmp/cos-drop-it.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home" "$DIR/Fonts"
RUN_ENV=(CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home")
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)

app_binary() {
  cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
  cp "$ROOT/Resources/"*.svg "$DIR/" 2>/dev/null || true
  local SOURCES=("$ROOT"/Sources/*.swift)
  SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/DropItRender.swift" \
    -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Vision -o "$DIR/drop-it-render"
}

if [[ "$MODE" == "render" ]]; then
  OUT="${2:?usage: run-drop-it.sh render <folder for the PNGs>}"
  mkdir -p "$OUT"
  app_binary
  env "${RUN_ENV[@]}" "$DIR/drop-it-render" render "${OUT:A}" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
  exit 0
fi
[[ "$MODE" == "check" ]] || { print -u2 "usage: run-drop-it.sh [check | render <dir>]"; exit 64; }

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  OUT="$(/usr/bin/python3 "$ROOT/Tests/drop-it-pins.py" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*pins: }%% passed*}"
  (( COUNT >= 40 )) || { print -u2 "drop it pins ran only $COUNT (expected at least 40)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library \
    "$ROOT/Sources/DropIt.swift" "$ROOT/Sources/Models.swift" "$ROOT/Tests/DropItChecks.swift" -framework AppKit -o "$DIR/drop-it-checks"
  OUT="$(env "${RUN_ENV[@]}" "$DIR/drop-it-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  # A floor on the count: a check that silently stops running must fail this.
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 92 )) || { print -u2 "drop it checks ran only $COUNT (expected at least 92)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "wiring" ]]; then
  app_binary
  # The last line must be the binary's own: an early exit 0 must never pass for a pass.
  OUT="$(env "${RUN_ENV[@]}" "$DIR/drop-it-render" check)" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  [[ "$OUT" == *"PASS: drop it wiring checks complete" ]] || { print -u2 "the drop it wiring checks did not finish"; exit 1; }
  COUNT="${${OUT##*wiring checks: }%% passed*}"
  (( COUNT >= 15 )) || { print -u2 "drop it wiring checks ran only $COUNT (expected at least 15)"; exit 1; }
fi

# By hand and for the mutation gate only (Tests/run.sh already builds the helper and runs both): the compiled helper against a
# loopback fixture.
if [[ "$LANE" == "helper" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
    -framework Security -framework AppKit -o "$DIR/cos-control-helper"
  /usr/bin/python3 "$ROOT/Tests/drop-it-helper-checks.py" "$DIR/cos-control-helper"
fi
print "PASS: drop it (0.5.371)"
