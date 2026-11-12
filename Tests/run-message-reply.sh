#!/bin/zsh
# Reply in the message reader (D4; Miles 2026-11-11): the words, session rule, model and effort gate and the reply store
# (Models.swift and DropIt.swift alone), then the wiring pins. The helper's effort and efforts contract runs in its self-test.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-message-reply.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
  "$ROOT/Sources/DropIt.swift" "$ROOT/Sources/Models.swift" "$ROOT/Tests/MessageReplyChecks.swift" -framework AppKit -o "$TMP/message-reply"
CFFIXED_USER_HOME="$TMP/home" HOME="$TMP/home" COS_CONTROL_TEST_HOME="$TMP/home" "$TMP/message-reply"
/usr/bin/python3 "$ROOT/Tests/message-reply-pins.py" "$ROOT"
