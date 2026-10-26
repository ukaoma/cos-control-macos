#!/bin/zsh
# 0.5.345 Wave A (plan r3): the wiring pins (Tests/dictation-parity-pins.py, which proves each pin can fail with in-memory
# mutants), then the pure rules (Tests/DictationParityChecks.swift) compiled with Sources/MacDictationCore.swift alone
# through the shared compile guard: the filler strip against the canonical fixture (sha256 pinned), the language gate,
# casing, Undo polish, "polish already fixed this", the picker, the swap wait, the audio breakers, the sound gate and the
# microphone fallback. Nothing is drawn, clicked, shown, posted, played or activated; no device is opened.
#   COS_DICTATION_PARITY_LANE=pins|checks run-dictation-parity.sh   one lane alone
# Hand-run: Tests/mutate-dictation-parity.py (the mutation lane, serial, green baseline first).
set -euo pipefail
ROOT="${0:A:h:h}"
LANE="${COS_DICTATION_PARITY_LANE:-all}"
BIN="$(mktemp /tmp/cos-dictation-parity.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  /usr/bin/python3 "$ROOT/Tests/dictation-parity-pins.py" "$ROOT"
fi
if [[ "$LANE" == "all" || "$LANE" == "checks" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "$ROOT/Sources/MacDictationCore.swift" "$ROOT/Tests/DictationParityChecks.swift" -o "$BIN"
  OUT="$("$BIN" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*dictation parity: }%% checks*}"
  (( COUNT >= 250 )) || { print -u2 "0.5.345 dictation parity checks ran only $COUNT (expected at least 250)"; exit 1; }
fi
