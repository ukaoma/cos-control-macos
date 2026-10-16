#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /private/tmp/cos-mac-recording-checks.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
COS_COMPILE_PROFILE=bounded "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MacRecordingCore.swift" "$ROOT/Tests/MacRecordingChecks.swift" -o "$DIR/checks"
"$DIR/checks"
# 0.5.310: the Meetings row reads the store's paused state (the label rule itself is checked above). Source pins only:
# the store needs the full app to run, so these prove the wiring exists, not its runtime behaviour.
python3 - "$ROOT/Sources/MacRecording.swift" "$ROOT/Sources/ControllerModel.swift" <<'PY'
import sys
store, model = (open(p).read() for p in sys.argv[1:3])
catch = store[store.index("    func deliverPending() {"):store.index("protocol MacCaptureSession")]
assert "} catch { failed = true; self.deliveryPaused = true;" in catch, "a failed delivery must mark the row paused"
assert catch.index("self.deliveryPaused = false") < catch.index("do {"), "a new delivery attempt must clear the paused state first"
assert "paused: macRecording.deliveryPaused)" in model, "the Meetings row must pass the store's paused state to its label"
print("PASS Mac recording paused-delivery wiring")
PY
# 0.5.313 (Miles 2026-10-15 field bugs): the silence warning is a live check only, and a cancelled panel task is not an
# error. Comments are stripped so an explanatory comment can never satisfy a pin.
python3 - "$ROOT/Sources/MacRecording.swift" <<'PY'
import re, sys
code = "\n".join(l for l in open(sys.argv[1]).read().splitlines() if not l.lstrip().startswith("//") and not l.lstrip().startswith("///"))
warn = code[code.index("    var signalWarning: String? {"):code.index("    var isRecording: Bool")]
assert "guard isRecording else { return nil }" in warn and warn.index("guard isRecording") < warn.index("MacRecordingSignal.warning("), \
    "the no-sound warning must show only while recording, never after stop or save"
prep = code[code.index("    func prepare(bridge: @escaping Bridge) async {"):code.index("    private func invoke(")]
assert re.search(r"\} catch is CancellationError \{\s*return\s*\} catch \{ available = false; self\.error = error\.localizedDescription \}", prep), \
    "a cancelled prepare (the panel's .task when Meetings goes away) must not set error or mark recording unavailable"
print("PASS Mac recording: live-only silence warning, cancelled prepare is not an error")
PY
# QA 0.5.313 pass 2: an interruption is shown once (the journal's line), never copied into the red error; a stop
# nobody made posts a notification; Recover is occupied before its first await and takes the transport from callers
# outside Meetings; a stranded Save re-reads the spool before saying the audio is not on this Mac. Comments stripped.
python3 - "$ROOT/Sources/MacRecording.swift" "$ROOT/Sources/ControllerModel.swift" <<'PY'
import sys
strip = lambda p: "\n".join(l for l in open(p).read().splitlines() if not l.lstrip().startswith("//"))
store, model = strip(sys.argv[1]), strip(sys.argv[2])
assert store.count("captureInterruption = reason") == 4 and "error = reason }" not in store and "self?.error = reason" not in store \
    and "self.captureInterruption = reason; self.error" not in store, "an interruption must not also set the red error"
stop = store[store.index("    private func finishStop() async {"):store.index("    func startFromMeetingSuggestion(")]
assert "if let reason = captureInterruption { stoppedOnItsOwn?(reason) }" in stop, "a stop nobody made must be reported"
assert "macRecording.stoppedOnItsOwn = { [weak self] reason in self?.meetingAudioNotifier.postRecordingStopped(reason) }" in model, \
    "the report must reach a notification"
rec = store[store.index("    func recover(_ value: MacRecordingManifest, bridge: Bridge? = nil) async -> RecoverOutcome {"):store.index("    var canKeepForLater: Bool {")]
assert rec.index('phase = "recovering"') < rec.index("await"), "Recover must be occupied before its first await"
assert "if let bridge, self.bridge == nil { self.bridge = bridge }" in rec and "phase = before" in rec, \
    "Recover takes a caller's transport and restores the phase on failure"
start = model.index("    func saveStranded(_ sessionId: String) {")
saved = model[start:model.index("        orphanBusy = true", start)]
assert "await self.macRecording.retainedCaptures()" in saved and "self.macRecording.recover(capture, bridge: self.macRecordingBridge)" in saved \
    and saved.index("retainedCaptures()") < saved.index("not on this Mac"), \
    "a stranded Save reads the spool fresh and passes the transport before claiming the audio is absent"
assert 'if store.canKeepForLater {' in store, "Keep audio is offered whenever the policy allows (silence or paused delivery)"
print("PASS Mac recording: one interruption line, stop notice, safe Recover and stranded Save, keep when paused")
PY
