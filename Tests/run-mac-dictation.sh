#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /private/tmp/cos-mac-dictation-checks.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MacDictationCore.swift" "$ROOT/Tests/MacDictationChecks.swift" -o "$DIR/checks"
"$DIR/checks"
# 0.5.305 crashed on the first microphone buffer: closures formed in the @MainActor capture class inherit main-actor
# isolation and Swift 6 traps when AVAudioEngine calls them from its own queue. Both audio callbacks stay @Sendable.
SRC="$ROOT/Sources/MacDictation.swift"
[[ $(grep -c -F 'installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in' "$SRC") == 1 ]] || { print -u2 "FAIL: dictation tap closure must be @Sendable (off-main AVAudioEngine callback)"; exit 1; }
[[ $(grep -c -F 'forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable _ in' "$SRC") == 1 ]] || { print -u2 "FAIL: engine change observer must be @Sendable (posted off-main)"; exit 1; }
[[ $(grep -c -E 'installTap\(|queue: nil\) \{' "$SRC") == 2 ]] || { print -u2 "FAIL: a new off-main audio callback needs the same @Sendable review and pin"; exit 1; }
print "PASS Mac dictation isolation pins: tap and engine-change callbacks are @Sendable"

