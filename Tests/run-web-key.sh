#!/bin/zsh
# Phone approvals (server 6.99.31, COS_WEB_KEY_AUTHORITY, default off). Sources/WebKeyCore.swift and HelperSources/PairingCore.swift
# compiled alone with Tests/WebKeyChecks.swift (ONE compile, through Tests/compile-guard.sh), run against vectors the server's
# own code made (Tests/fixtures/web-key/golden.json), then the pins (Tests/web-key-pins.py). No keychain, no Secure Enclave, no
# Touch ID, no helper, no server: every effect is a stand-in, and state files go to a temporary folder.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-web-key.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/WebKeyCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/Tests/WebKeyChecks.swift" -o "$DIR/web-key-checks"
OUT="$(TMPDIR="$DIR/" "$DIR/web-key-checks" "$ROOT/Tests/fixtures/web-key/golden.json")" || { print -r -- "$OUT"; exit 1; }
print -r -- "$OUT"
COUNT="${${OUT##*checks: }%% passed*}"
# A floor on the count: a check that silently stops running must fail this, not pass it.
(( COUNT >= 135 )) || { print -u2 "web key checks ran only $COUNT (expected at least 135)"; exit 1; }
/usr/bin/python3 "$ROOT/Tests/web-key-pins.py" "$ROOT"
