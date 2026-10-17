#!/bin/zsh
# 0.5.317 dictation for everyone, Control side. Small compiles, one at a time through Tests/compile-guard.sh:
#   1. the helper's pure half (HelperSources/ProviderStatusCore.swift + Tests/DictationEveryoneChecks.swift): the
#      compatibility gate, answers and their one action, WER on the pinned reference, the engine test, the tool path;
#   2. the bundled FluidAudio tool's Info.plist checker, against throwaway binaries (clang, not Swift);
#   3. the release entitlements rule for the tool, on throwaway bundles;
#   4. the source pins (Tests/dictation-everyone-pins.py).
# The store, the setup guide rows and the failure card's action are checked in their own lanes
# (run-transcription-settings.sh, run-provider-connect.sh, run-mac-dictation.sh). No server, audio or window.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /private/tmp/cos-dictation-everyone.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/Tests/DictationEveryoneChecks.swift" -o "$DIR/checks"
OUT="$("$DIR/checks" "$ROOT/Resources/VoiceBenchmark/speech-30s.txt")" || { print -r -- "$OUT"; exit 1; }
print -r -- "$OUT"
COUNT="${${OUT##*checks: }%% passed*}"
(( COUNT >= 64 )) || { print -u2 "dictation-everyone checks ran only $COUNT (expected at least 64)"; exit 1; }
# The pinned reference is the file the helper verifies by SHA-256.
[[ "$(/usr/bin/shasum -a 256 "$ROOT/Resources/VoiceBenchmark/speech-30s.txt" | /usr/bin/awk '{print $1}')" == "$(/usr/bin/grep -o 'referenceSHA256 = "[0-9a-f]*"' "$ROOT/HelperSources/ProviderStatusCore.swift" | /usr/bin/grep -o '[0-9a-f]\{64\}')" ]] \
  || { print -u2 "FAIL: speech-30s.txt does not match VoiceAccuracy.referenceSHA256"; exit 1; }
/usr/bin/python3 "$ROOT/Tests/check-fluidaudio-cli.py" --selftest "$ROOT/Resources/fluidaudio-cli.json" "$DIR/cli-selftest"
mkdir -p "$DIR/entitlements"
/bin/cp /usr/bin/true "$DIR/entitlements/sample"
/usr/bin/python3 "$ROOT/Tests/check-release-entitlements.py" --selftest "$DIR/entitlements" "$DIR/entitlements/sample"
/usr/bin/python3 "$ROOT/Tests/dictation-everyone-pins.py" "$ROOT"
