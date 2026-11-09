#!/bin/zsh
# 0.5.380 (preview engine phase 1, Miles's 11/08 screenshot): the Sessions reader shows an assistant reply's local links as
# their cards' words and drops its local image tokens, as Control Web does. The rules (Sources/SessionReplyLinks.swift) run in
# Tests/SessionReplyLinksChecks.swift, compiled with that file alone, on the table and on the golden replies the server's own
# functions produced (Tests/fixtures/session-reply-links-golden.json); Tests/session-reply-links-parity-pins.py compares the
# port with the server's session-links.ts and imageTokens, and pins where the reader applies it. Caller must own the shared
# Swift lane (one full compile machine-wide).
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /tmp/cos-session-reply-links.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
/usr/bin/python3 "$ROOT/Tests/session-reply-links-parity-pins.py" "$ROOT"
COS_COMPILE_PROFILE=bounded /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc \
  -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/SessionReplyLinks.swift" "$ROOT/Tests/SessionReplyLinksChecks.swift" -o "$OUT/checks"
"$OUT/checks" "$ROOT/Tests/fixtures/session-reply-links-golden.json"
