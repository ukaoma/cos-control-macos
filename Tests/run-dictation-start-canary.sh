#!/bin/zsh
# 0.5.327: press to first buffer on THIS Mac's real default microphone (Tests/DictationStartCanary.swift). By hand only:
# it opens the microphone for a few seconds in total. The capture code is lifted verbatim from Sources/MacDictation.swift.
#   zsh Tests/run-dictation-start-canary.sh [rounds] [evidence dir]
# Exit 2 (SKIP) when this process may not use the microphone; then read the timing file after a real dictation instead:
#   python3 Tests/dictation-start-timing.py
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /private/tmp/cos-dictation-start-canary.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
/usr/bin/python3 - "$ROOT/Sources/MacDictation.swift" "$DIR/DictationCapture.swift" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
def lift(key):
    assert src.count(key) == 1, key
    start = src.index(key); depth, i = 0, src.index("{", start)
    while True:
        c = src[i]
        if c == "{": depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0: break
        i += 1
    return src[start:i + 1]
parts = [lift("struct DictationMicrophone: Identifiable, Equatable {"), lift("enum DictationAudioDevices {"),
         lift("@MainActor final class DictationMicrophoneCapture {"), lift("private final class DictationConverter: @unchecked Sendable {")]
open(sys.argv[2], "w", encoding="utf-8").write("import Foundation\nimport AVFoundation\nimport CoreAudio\n\n" + "\n\n".join(parts) + "\n")
PY
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MacDictationCore.swift" "$DIR/DictationCapture.swift" "$ROOT/Tests/DictationStartCanary.swift" -o "$DIR/canary"
"$DIR/canary" "${1:-5}" "${2:-$DIR/evidence}"
