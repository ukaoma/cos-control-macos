#!/bin/zsh
# 0.5.345 (plan r3): Control and the server roll back together, and history decoding is all-or-nothing, so 0.5.344 must
# read what 0.5.345 writes. Compiles today's MacDictationCore.swift with a writer, then ce9b71c's (0.5.344, from git)
# with a reader, one guarded compile at a time, and asserts movedTo == nil and the record count. Fictional text only.
set -euo pipefail
ROOT="${0:A:h:h}"
BASE="${COS_HISTORY_BACKCOMPAT_BASE:-ce9b71c}"
DIR="$(mktemp -d /private/tmp/cos-history-backcompat.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
git -C "$ROOT" show "$BASE:Sources/MacDictationCore.swift" > "$DIR/OldCore.swift"
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MacDictationCore.swift" "$ROOT/Tests/backcompat/HistoryWrite.swift" -o "$DIR/write"
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$DIR/OldCore.swift" "$ROOT/Tests/backcompat/HistoryRead.swift" -o "$DIR/read"
"$DIR/write" "$DIR/dictations.json"
"$DIR/read" "$DIR/dictations.json"
