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
# Pins read code only: a comment quoting a pinned line must never satisfy it.
CODE="$(grep -v -E '^[[:space:]]*//' "$SRC")"
[[ $(print -r -- "$CODE" | grep -c -F 'installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in') == 1 ]] || { print -u2 "FAIL: dictation tap closure must be @Sendable (off-main AVAudioEngine callback)"; exit 1; }
[[ $(print -r -- "$CODE" | grep -c -F 'forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable _ in') == 1 ]] || { print -u2 "FAIL: engine change observer must be @Sendable (posted off-main)"; exit 1; }
# Every place a closure can be handed to another thread or to AppKit's event dispatch, reviewed 0.5.307: the tap, the
# engine observer, the global key-and-click monitor and the two local monitors (shortcut and recorder). A new site of
# any of these kinds changes the count and must get the same isolation review before the count is updated.
[[ $(print -r -- "$CODE" | grep -c -E 'installTap\(|queue: *nil\)|DispatchQueue|OperationQueue\(|DispatchSource|addGlobalMonitorForEvents|addLocalMonitorForEvents') == 5 ]] || { print -u2 "FAIL: a new off-main or event-monitor callback site needs the @Sendable / isolation review, then this count"; exit 1; }
# The shortcut monitors also take clicks (⌥-click is a chord), and NSEvent raises on a mouse event's keyCode.
[[ $(print -r -- "$CODE" | grep -c -F 'let key = isKey ? event.keyCode : 0') == 1 && $(print -r -- "$CODE" | grep -c -F 'event.keyCode') == 2 ]] || { print -u2 "FAIL: keyCode must be read only from key events in the shortcut monitors"; exit 1; }
# 0.5.313: clicks reach the tracker as clicks (time-windowed chord), never as a key down, or any click while talking cancels.
[[ $(print -r -- "$CODE" | grep -c -F ': pointer ? current.pointerDown(at: time) : current.keyDown()') == 1 && $(print -r -- "$CODE" | grep -c -F 'pointer: !isKey, keyCode: key, raw: raw, at: time') == 1 ]] || { print -u2 "FAIL: shortcut monitors must feed clicks to pointerDown with the event time"; exit 1; }
print "PASS Mac dictation isolation pins: audio callbacks @Sendable, callback sites reviewed, click-safe keyCode"
# 0.5.309 Wispr-style dictation: pet pill and lists, the Dock overlay, copy-then-insert-at-focus, private history, the
# Dictionary route and the helper verb. Text only; the pure rules run in MacDictationChecks above. The overlay's five
# Combine sinks (reviewed 0.5.309) each hop to the main actor before reading state; that count is pinned there.
/usr/bin/python3 "$ROOT/Tests/dictation-wispr-pins.py" "$ROOT"
