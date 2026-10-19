#!/bin/zsh
# K1 P10 (plan v4 10.1, 11, 12): key lanes in COS Control. Every compile goes through Tests/compile-guard.sh, one at a time.
#   run-key-lanes.sh                                  the gate: the wiring pins and P8 copy parity (Tests/key-lanes-pins.py),
#                                                     the app's decisions and store against a stand-in helper, compiled with
#                                                     KeyLanes.swift and Models.swift alone (Tests/KeyLanesChecks.swift), then
#                                                     the helper's grammar and whitelist alone (Tests/KeyLanesHelperChecks.swift)
#   COS_KEY_LANES_LANE=pins|models|core|onerow|helper run-key-lanes.sh   one lane alone (Tests/mutate-key-lanes.py); helper
#                                                     only by name; onerow (QA G2) is one full app compile
#   run-key-lanes.sh golden <out.json>               the K0 G-control replay against this checkout (lanes off, 6.79.0 status):
#                                                     Tests/KeyLanesSnapshot.run.sh --compare Tests/KeyLanesSnapshot.golden-5cdb833.json
# The compiled helper's key-lanes verb runs in Tests/run.sh (Tests/key-lanes-helper-checks.py). Fixtures only: no helper
# binary in the app lanes, no server, no window, no real key.
set -euo pipefail
ROOT="${0:A:h:h}"
MODE="${1:-check}"
LANE="${COS_KEY_LANES_LANE:-all}"
if [[ "$MODE" == "golden" ]]; then
  exec zsh "$ROOT/Tests/KeyLanesSnapshot.run.sh" "${2:?usage: run-key-lanes.sh golden <out.json>}" --compare "$ROOT/Tests/KeyLanesSnapshot.golden-5cdb833.json"
fi
if [[ "$MODE" == "render" ]]; then
  OUT="${2:?usage: run-key-lanes.sh render <folder for the PNGs>}"; mkdir -p "$OUT"
  RDIR="$(mktemp -d /tmp/cos-key-lanes-render.XXXXXX)"; trap 'rm -rf "$RDIR"' EXIT; mkdir -p "$RDIR/cos-key-lanes-home"
  SOURCES=("$ROOT"/Sources/*.swift); SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "${SOURCES[@]}" "$ROOT/Tests/KeyLanesRender.swift" -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$RDIR/key-lanes-render"
  mkdir -p "$RDIR/Fonts"; cp "$ROOT/Resources/Fonts/"*.ttf "$RDIR/Fonts/"; cp "$ROOT/Resources/"*.svg "$RDIR/"
  H="$RDIR/cos-key-lanes-home"; CFFIXED_USER_HOME="$H" HOME="$H" COS_CONTROL_TEST_HOME="$H" "$RDIR/key-lanes-render" "${OUT:A}"
  exit 0
fi
[[ "$MODE" == "check" ]] || { print -u2 "usage: run-key-lanes.sh [check | golden <out.json> | render <dir>]"; exit 64; }
DIR="$(mktemp -d /tmp/cos-key-lanes.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home"
RUN_ENV=(CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home")
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  OUT="$(/usr/bin/python3 "$ROOT/Tests/key-lanes-pins.py" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*pins: }%% passed*}"
  (( COUNT >= 50 )) || { print -u2 "key lanes pins ran only $COUNT (expected at least 50)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library \
    "$ROOT/Sources/KeyLanes.swift" "$ROOT/Sources/Models.swift" "$ROOT/Tests/KeyLanesChecks.swift" -framework AppKit -o "$DIR/key-lanes-checks"
  OUT="$(env "${RUN_ENV[@]}" "$DIR/key-lanes-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 101 )) || { print -u2 "key lanes checks ran only $COUNT (expected at least 101)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "core" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library \
    "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/Tests/KeyLanesHelperChecks.swift" -o "$DIR/key-lanes-helper-core"
  OUT="$("$DIR/key-lanes-helper-core")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 46 )) || { print -u2 "key lanes helper core checks ran only $COUNT (expected at least 46)"; exit 1; }
fi

# QA G2: the shipping case, 6.80.0 with lanes off and no key, is the 6.79.0 panel plus exactly one Settings row. One full
# app compile through the guard.
if [[ "$LANE" == "all" || "$LANE" == "onerow" ]]; then
  ORDIR="$DIR/cos-key-lanes-onerow"; mkdir -p "$ORDIR"
  SOURCES=("$ROOT"/Sources/*.swift); SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library \
    "${SOURCES[@]}" "$ROOT/Tests/KeyLanesOneRowRender.swift" -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit \
    -o "$DIR/key-lanes-onerow"
  mkdir -p "$DIR/Fonts"; cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"; cp "$ROOT/Resources/"*.svg "$DIR/"
  OUT="$(CFFIXED_USER_HOME="$ORDIR" HOME="$ORDIR" COS_CONTROL_TEST_HOME="$ORDIR" "$DIR/key-lanes-onerow")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
fi

# By hand and for the mutation gate only (Tests/run.sh already builds the helper and runs this script against it).
if [[ "$LANE" == "helper" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
    -framework Security -framework AppKit -o "$DIR/cos-control-helper"
  /usr/bin/python3 "$ROOT/Tests/key-lanes-helper-checks.py" "$DIR/cos-control-helper"
fi
print "PASS: key lanes (K1 P10)"
