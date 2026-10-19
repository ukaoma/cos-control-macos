#!/bin/zsh
# 0.5.314: executes the real DictationSoundPlayer (lifted verbatim from Sources/MacDictation.swift) in Swift 6 mode and
# plays a sound to its end. 0.5.313 trapped there. See Tests/DictationSoundRuntimeCheck.swift.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /private/tmp/cos-dictation-sound-runtime.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
/usr/bin/python3 - "$ROOT/Sources/MacDictation.swift" "$DIR/DictationSoundPlayer.swift" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
start = src.index("final class DictationSoundPlayer: @unchecked Sendable {")
assert src.count("final class DictationSoundPlayer: @unchecked Sendable {") == 1
depth, i = 0, src.index("{", start)
while True:
    c = src[i]
    if c == "{": depth += 1
    elif c == "}":
        depth -= 1
        if depth == 0: break
    i += 1
open(sys.argv[2], "w", encoding="utf-8").write("import Foundation\nimport AVFoundation\nimport os\n\n" + src[start:i + 1] + "\n")
PY
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MacDictationCore.swift" "$DIR/DictationSoundPlayer.swift" "$ROOT/Tests/DictationSoundRuntimeCheck.swift" -o "$DIR/check"
"$DIR/check"
