#!/bin/zsh
# Glasses pairing (contract 2026-10-09): HelperSources/PairingCore.swift alone against fixtures from a real Tailscale
# (Tests/PairingCoreChecks.swift). Foundation only, so the compile is small; it goes through Tests/compile-guard.sh.
# The app's Glasses rules run in Tests/ProviderConnectChecks.swift, the compiled verbs in Tests/pairing-helper-checks.py.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-pairing-core.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/HelperSources/PairingCore.swift" "$ROOT/Tests/PairingCoreChecks.swift" -o "$DIR/pairing-core-checks"
OUT="$("$DIR/pairing-core-checks" "$ROOT/Tests/fixtures/pairing")" || { print -r -- "$OUT"; exit 1; }
print -r -- "$OUT"
# A floor on the count: a check that silently stops running must fail this.
COUNT="${${OUT##*checks: }%% passed*}"
(( COUNT >= 90 )) || { print -u2 "pairing core checks ran only $COUNT (expected at least 90)"; exit 1; }
