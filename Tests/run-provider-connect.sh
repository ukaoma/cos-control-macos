#!/bin/zsh
# Connect your AI (onboarding P1). Three parts, one compile at a time through Tests/compile-guard.sh:
#   1. provider-status's core against fixtures (Tests/run-provider-status.sh);
#   2. the app's model alone (Sources/ProviderConnectModel.swift + Tests/ProviderConnectChecks.swift, Foundation only);
#   3. the wiring pins (Tests/provider-connect-pins.py).
# Nothing opens Terminal, an app, a link or System Settings: every effect in the checks is a stand-in.
set -euo pipefail
ROOT="${0:A:h:h}"
"$ROOT/Tests/run-provider-status.sh"
DIR="$(mktemp -d /tmp/cos-provider-connect.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/ProviderConnectModel.swift" "$ROOT/Tests/ProviderConnectChecks.swift" -o "$DIR/provider-connect-checks"
HOME_DIR="$DIR/connect home.ü"
mkdir -p "$HOME_DIR"
# A floor on the count: a check that silently stops running must fail this, not pass it (QA 2026-10-08 W4).
# 0.5.390 line: the checks read the shared 14-character code vectors (Tests/fixtures/pairing/pair-long-code.vectors.json).
OUT="$(CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" "$DIR/provider-connect-checks" "$ROOT/Tests/fixtures/pairing/pair-long-code.vectors.json")" || { print -r -- "$OUT"; exit 1; }
print -r -- "$OUT"
COUNT="${${OUT##*checks: }%% passed*}"
# 578 at 0.5.368 (the phone row hides on a server without its route); 566 at 0.5.367 (Open COS on your phone: its rules and its
# state); 194 before.
# 600 at 0.5.387 (D1: Install Claude Code in Terminal, 22 checks).
# 730 on the 0.5.390 line (the 14-character pairing code, its card rules and countdowns: 736 ran).
(( COUNT >= 730 )) || { print -u2 "Connect your AI checks ran only $COUNT (expected at least 730)"; exit 1; }
# The pet introduction after the REAL character-scale migration (Models.swift), on a scratch defaults suite.
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/ProviderConnectModel.swift" "$ROOT/Tests/PetIntroMigrationCheck.swift" -o "$DIR/pet-intro-check"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" "$DIR/pet-intro-check"
/usr/bin/python3 "$ROOT/Tests/provider-connect-pins.py" "$ROOT"
