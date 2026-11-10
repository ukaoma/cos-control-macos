#!/bin/zsh
# Lane D1 (0.5.387): "Dictate into Mac apps" on with no start shortcut says so, with the recorder right there.
#   pins (Tests/dictation-shortcut-gap-pins.py), then DictationShortcutGap lifted out of Sources/MacDictation.swift and
#   compiled alone with Tests/DictationShortcutGapChecks.swift (the lift pattern Tests/run-mac-dictation.sh uses).
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-dictation-gap.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
OUT="$(/usr/bin/python3 "$ROOT/Tests/dictation-shortcut-gap-pins.py" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
print -r -- "$OUT"
COUNT="${${OUT##*pins: }%% passed*}"
(( COUNT >= 7 )) || { print -u2 "dictation shortcut gap pins ran only $COUNT (expected at least 7)"; exit 1; }
/usr/bin/python3 - "$ROOT/Sources/MacDictation.swift" "$DIR/DictationShortcutGap.swift" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
key = "enum DictationShortcutGap {"
assert src.count(key) == 1, key
start = src.index(key); depth, i = 0, src.index("{", start)
while True:
    c = src[i]
    if c == "{": depth += 1
    elif c == "}":
        depth -= 1
        if depth == 0: break
    i += 1
open(sys.argv[2], "w", encoding="utf-8").write("import Foundation\n\n" + src[start:i + 1] + "\n")
PY
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 \
  -strict-concurrency=complete -parse-as-library "$DIR/DictationShortcutGap.swift" "$ROOT/Tests/DictationShortcutGapChecks.swift" -o "$DIR/gap-checks"
OUT="$("$DIR/gap-checks")" || { print -r -- "$OUT"; exit 1; }
print -r -- "$OUT"
COUNT="${${OUT##*checks: }%% passed*}"
(( COUNT >= 11 )) || { print -u2 "dictation shortcut gap checks ran only $COUNT (expected at least 11)"; exit 1; }
