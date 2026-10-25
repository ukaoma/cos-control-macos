#!/bin/zsh
# 0.5.344 part 2, Your style (plan r2 section 2): the wiring pins (Tests/voice-style-pins.py, which proves each pin can
# fail with in-memory mutants), then the ledger, the classifier and its filters, promotion, retirement, tombstones,
# ranking, the pill once ever and the sync against a fake server (Tests/VoiceStyleChecks.swift), compiled with
# Sources/MacDictationCore.swift alone through the shared compile guard. Nothing is drawn, clicked, shown, posted or activated.
#   COS_VOICE_STYLE_LANE=pins|checks run-voice-style.sh   one lane alone
# Hand-run: Tests/mutate-voice-style.py (the mutation lane, serial, green baseline first).
set -euo pipefail
ROOT="${0:A:h:h}"
LANE="${COS_VOICE_STYLE_LANE:-all}"
BIN="$(mktemp /tmp/cos-voice-style.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  /usr/bin/python3 "$ROOT/Tests/voice-style-pins.py" "$ROOT"
fi
if [[ "$LANE" == "all" || "$LANE" == "checks" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "$ROOT/Sources/MacDictationCore.swift" "$ROOT/Tests/VoiceStyleChecks.swift" -o "$BIN"
  OUT="$("$BIN")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*voice style: }%% checks*}"
  (( COUNT >= 120 )) || { print -u2 "0.5.344 voice style checks ran only $COUNT (expected at least 120)"; exit 1; }
fi
