#!/bin/zsh
# 0.5.342 Your edit, confirmed: the wiring pins (Tests/edit-confirm-pins.py, which also proves each pin can fail with
# in-memory mutants), then the rules against fictional fixtures (Tests/EditConfirmChecks.swift), compiled with
# Sources/MacDictationCore.swift alone through the shared compile guard. Nothing is drawn, clicked, shown or activated.
#   COS_EDIT_CONFIRM_LANE=pins|checks run-edit-confirm.sh   one lane alone
# Hand-run: Tests/mutate-edit-confirm.py (the mutation lane, serial, green baseline first).
set -euo pipefail
ROOT="${0:A:h:h}"
LANE="${COS_EDIT_CONFIRM_LANE:-all}"
BIN="$(mktemp /tmp/cos-edit-confirm.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  /usr/bin/python3 "$ROOT/Tests/edit-confirm-pins.py" "$ROOT"
fi
if [[ "$LANE" == "all" || "$LANE" == "checks" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "$ROOT/Sources/MacDictationCore.swift" "$ROOT/Tests/EditConfirmChecks.swift" -o "$BIN"
  OUT="$("$BIN")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*edit confirm: }%% checks*}"
  (( COUNT >= 80 )) || { print -u2 "0.5.342 edit confirm checks ran only $COUNT (expected at least 80)"; exit 1; }
fi
