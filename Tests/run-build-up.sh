#!/bin/zsh
# 0.5.343 Build-up, in place: the wiring pins (Tests/build-up-pins.py, which also proves each pin can fail with in-memory
# mutants), then the rules against fixtures (Tests/BuildUpChecks.swift), compiled with Sources/Models.swift alone through
# the shared compile guard. Nothing is drawn, clicked, shown or activated.
# Then the view lane: the real COSBuildUp, live, off screen (Tests/BuildUpViewChecks.swift), compiled with the app sources.
#   COS_BUILD_UP_LANE=pins|checks|view run-build-up.sh   one lane alone
# Hand-run: Tests/mutate-build-up.py (the mutation lane, serial, green baseline first) and Tests/run-build-up-render.sh
# (static PNGs of the build, never a gate).
set -euo pipefail
ROOT="${0:A:h:h}"
LANE="${COS_BUILD_UP_LANE:-all}"
BIN="$(mktemp /tmp/cos-build-up.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  /usr/bin/python3 "$ROOT/Tests/build-up-pins.py" "$ROOT"
  /usr/bin/python3 "$ROOT/Tests/motion-gate-pins.py" "$ROOT"
fi
if [[ "$LANE" == "all" || "$LANE" == "checks" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "$ROOT/Sources/Models.swift" "$ROOT/Tests/BuildUpChecks.swift" -framework AppKit -o "$BIN"
  OUT="$("$BIN")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*build up: }%% checks*}"
  (( COUNT >= 120 )) || { print -u2 "0.5.343 build up checks ran only $COUNT (expected at least 120)"; exit 1; }
fi
if [[ "$LANE" == "all" || "$LANE" == "view" ]]; then
  SOURCES=("$ROOT"/Sources/*.swift)
  SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
  VIEW="$(mktemp -d /tmp/cos-build-up-view.XXXXXX)"
  trap 'rm -f "$BIN"; rm -rf "$VIEW"' EXIT
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "${SOURCES[@]}" "$ROOT/Tests/BuildUpViewChecks.swift" -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$VIEW/view-checks"
  mkdir -p "$VIEW/home" "$VIEW/Fonts"
  # The app's fonts and marks beside the binary, as in the app bundle, so rows measure as they ship.
  cp "$ROOT/Resources/Fonts/"*.ttf "$VIEW/Fonts/"
  cp "$ROOT/Resources/"*.svg "$VIEW/"
  OUT="$(CFFIXED_USER_HOME="$VIEW/home" HOME="$VIEW/home" COS_CONTROL_TEST_HOME="$VIEW/home" "$VIEW/view-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*build up view: }%% checks*}"
  (( COUNT >= 30 )) || { print -u2 "0.5.343 build up view checks ran only $COUNT (expected at least 30)"; exit 1; }
fi
