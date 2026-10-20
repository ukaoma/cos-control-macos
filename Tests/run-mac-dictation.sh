#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /private/tmp/cos-mac-dictation-checks.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
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
# 0.5.314: scheduleFile/scheduleBuffer joined the census after 0.5.313 shipped an unreviewed scheduleFile completion that
# trapped on every dictation sound. It is built by a nonisolated static (playedBack), which the runtime check executes.
# 0.5.315: the mute's IOProc (built in MacDictationCore's DictationMuteIO, outside every actor, executed off-main by the
# checks) and the default-output listener (built by the nonisolated outputListener, delivered on .main) joined it.
[[ $(print -r -- "$CODE" | grep -c -E 'installTap\(|queue: *nil\)|DispatchQueue|OperationQueue\(|DispatchSource|addGlobalMonitorForEvents|addLocalMonitorForEvents|scheduleFile\(|scheduleBuffer\(|scheduleSegment\(|AudioDeviceCreateIOProcIDWithBlock\(|AudioObjectAddPropertyListenerBlock\(') == 8 ]] || { print -u2 "FAIL: a new off-main or event-monitor callback site needs the @Sendable / isolation review, then this count"; exit 1; }
[[ $(print -r -- "$CODE" | grep -c -F 'completionCallbackType: .dataPlayedBack, completionHandler: Self.playedBack(self, id: id))') == 1 && $(print -r -- "$CODE" | grep -c -F 'private nonisolated static func playedBack(') == 1 ]] || { print -u2 "FAIL: the sound completion must be built by the nonisolated playedBack (0.5.313 trapped)"; exit 1; }
zsh "$ROOT/Tests/run-dictation-sound-runtime.sh"
# 0.5.315: the quiet controller, lifted verbatim, type-checks in Swift 6 strict mode against the core (seconds, not a full
# Control compile). It cannot RUN here: a real mute would silence this Mac and needs System Audio Recording.
# 0.5.318: SystemAudioPermission (TCC's preflight and request) is lifted with it; its SystemAudioFact is in the guide model.
/usr/bin/python3 - "$SRC" "$DIR/DictationQuiet.swift" <<'PY'
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
lifted = lift("final class DictationQuietController: @unchecked Sendable {") + "\n\n" + lift("enum SystemAudioPermission {")
open(sys.argv[2], "w", encoding="utf-8").write('import Foundation\nimport CoreAudio\nimport AudioToolbox\nimport os\n\nlet dictationLog = Logger(subsystem: "com.gotcos.control.tests", category: "dictation")\n\n' + lifted + "\n")
PY
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -typecheck -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MacDictationCore.swift" "$ROOT/Sources/PermissionGuideModel.swift" "$DIR/DictationQuiet.swift"
print "PASS dictation quiet controller and system audio permission type-check in Swift 6 (lifted verbatim; not executed)"
# The shortcut monitors also take clicks (⌥-click is a chord), and NSEvent raises on a mouse event's keyCode.
[[ $(print -r -- "$CODE" | grep -c -F 'let key = isKey ? event.keyCode : 0') == 1 && $(print -r -- "$CODE" | grep -c -F 'event.keyCode') == 2 ]] || { print -u2 "FAIL: keyCode must be read only from key events in the shortcut monitors"; exit 1; }
# 0.5.313: clicks reach the HOLD tracker as clicks (time-windowed chord), never as a key down, or any click while talking
# cancels; the toggle and Fix trackers keep every click a chord (QA pass 2), so only the hold feed passes clickWindow.
[[ $(print -r -- "$CODE" | grep -c -F ': pointer && clickWindow ? current.pointerDown(at: time) : current.keyDown()') == 1 && $(print -r -- "$CODE" | grep -c -F 'clickWindow: true') == 1 && $(print -r -- "$CODE" | grep -c -F 'pointer: !isKey, keyCode: key, raw: raw, at: time') == 1 ]] || { print -u2 "FAIL: shortcut monitors must feed clicks to pointerDown with the event time"; exit 1; }
print "PASS Mac dictation isolation pins: audio callbacks @Sendable, callback sites reviewed, click-safe keyCode"
# 0.5.309 Wispr-style dictation: pet pill and lists, the Dock overlay, copy-then-insert-at-focus, private history, the
# Dictionary route and the helper verb. Text only; the pure rules run in MacDictationChecks above. The overlay's five
# Combine sinks (reviewed 0.5.309) each hop to the main actor before reading state; that count is pinned there.
/usr/bin/python3 "$ROOT/Tests/dictation-wispr-pins.py" "$ROOT"
# 0.5.325 AI polish: where DictationPolish and DictationPolishBridge are wired (text only; the rules run in the checks above).
/usr/bin/python3 "$ROOT/Tests/dictation-polish-pins.py" "$ROOT"
# 0.5.331 paste first, polish in place: the toggle, never activating, the focus gate, the deferred watch and the timing
# fields, at their call sites (the rules run in MacDictationChecks above), with in-memory mutants that must fail.
/usr/bin/python3 "$ROOT/Tests/dictation-swap-pins.py" "$ROOT"
# 0.5.326 release tail: where DictationReleaseTail and DictationTiming are wired (the rules run in MacDictationChecks).
/usr/bin/python3 "$ROOT/Tests/dictation-tail-pins.py" "$ROOT"
# 0.5.327 truthful start: STARTING until the first buffer, then LISTENING, the sound and the mute; no microphone list on
# the press; the spare engine never started; start numbers and failure codes on the timing line (rules in the checks).
/usr/bin/python3 "$ROOT/Tests/dictation-start-pins.py" "$ROOT"
# 0.5.328 smooth start: no Core Audio, engine or other-app Accessibility work on the main actor while a dictation starts.
/usr/bin/python3 "$ROOT/Tests/dictation-smooth-pins.py" "$ROOT"
# 0.5.330 hold to dictate "lock": every press that is not a dictation is written, the keyboard is watched while the hold
# key is believed down, a busy press says so, and the settings live in the Dictation tab.
/usr/bin/python3 "$ROOT/Tests/dictation-lock-pins.py" "$ROOT"
# 0.5.317: dictation for everyone (the helper core, the CLI checks, the pins).
zsh "$ROOT/Tests/run-dictation-everyone.sh"
