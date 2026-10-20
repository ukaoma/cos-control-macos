#!/usr/bin/env python3
"""0.5.328 smooth start: no CoreAudio, AVAudioEngine or other-app Accessibility work on the main actor while a dictation
starts. Each failure names its behaviour as "pin failed [<behaviour>]". Code only: comments never satisfy a pin. The rules
(the stall meter, the queues' order, the line) run in MacDictationChecks; Tests/run-dictation-start-canary.sh measures the
main thread's longest stall on this Mac's real microphone, the old way and the new.

Miles, 2026-10-19 on 0.5.327: "the animation stops as the new listening pill comes in." quietMs was 1.1 to 2.2 s on the
main actor; the pet is a TimelineView on the main actor, so it stopped.

    python3 Tests/dictation-smooth-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
read = lambda p: (root / p).read_text(encoding="utf-8")


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


def pin(ok, behaviour, why):
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")


def body(src, opener):
    pin(src.count(opener) == 1, "source shape", f"{opener!r} must appear exactly once")
    start = src.index(opener)
    depth, i, seen = 0, start, False
    while i < len(src):
        if src[i] == "{":
            depth += 1; seen = True
        elif src[i] == "}":
            depth -= 1
            if seen and depth == 0:
                return src[start:i + 1]
        i += 1
    return src[start:]


def order(src, needles, behaviour, why):
    pin(all(n in src for n in needles), behaviour, why)
    found = [src.index(n) for n in needles]
    pin(found == sorted(found), behaviour, why)


d = code(read("Sources/MacDictation.swift"))
core = code(read("Sources/MacDictationCore.swift"))
app = code(read("Sources/COSControlApp.swift"))
pet = code(read("Sources/SessionPet.swift"))

# 1. The three audio classes are not main-actor classes: their work runs on DictationAudioQueues.
for name in ("DictationQuietController", "DictationSoundPlayer", "DictationMicrophoneCapture"):
    pin(f"@MainActor final class {name}" not in d and f"final class {name}: @unchecked Sendable {{" in d, "audio off main",
        f"{name} is not a main-actor class (it lives on a DictationAudioQueues queue)")
queues = body(core, "enum DictationAudioQueues {")
pin('DispatchQueue(label: "com.gotcos.control.dictation.input", qos: .userInteractive)' in queues
    and 'DispatchQueue(label: "com.gotcos.control.dictation.output", qos: .userInitiated)' in queues
    and "queue.async { done.resume(with: Result { try work() }) }" in queues, "audio off main",
    "two serial queues, and perform runs its work on the queue it names")

store = body(d, "@MainActor final class MacDictationStore: ObservableObject {")
start = body(store, "    func start() {")
# 2. No Core Audio object, engine or sound is built or started by the store itself.
for api in ("AudioHardwareCreateProcessTap", "AudioHardwareCreateAggregateDevice", "AudioDeviceStart(", "AVAudioEngine()",
            "engine.start()", "engine.prepare()", "DictationQuietController()", "soundPlayer.play("):
    pin(api not in store, "no audio setup on main", f"the store never calls {api} itself")
pin("    private let quiet = DictationQuietHandle()" in store, "no audio setup on main", "the store reaches the mute only through DictationQuietHandle")
handle = body(d, "@MainActor final class DictationQuietHandle {")
for method, call in (("begin", "controller.begin(mode: mode, macRecording: macRecording)"), ("end", "controller.end()"),
                     ("restoreAfterInterruptedRun", "controller.restoreAfterInterruptedRun()")):
    fn = body(handle, f"    func {method}(")
    order(fn, ["DictationAudioQueues.output.async {", call], "quiet queued",
          f"the handle's {method} queues the controller's {method} on the output queue and returns")
pin(handle.count("DictationAudioQueues.output.sync") == 1 and "func flush() { DictationAudioQueues.output.sync {} }" in handle
    and "COSAppDelegate.onTerminate = { model.dictation.cancel(); model.dictation.flushAudio();" in app
    and "    func flushAudio() { quiet.flush() }" in store, "quit restores",
    "only quit waits on the output queue, after cancel, so a queued unmute or volume restore runs before exit")
play = body(store, "    private func play(_ url: URL, volume: Float, played: (@MainActor @Sendable (Int) -> Void)? = nil) {")
order(play, ["DictationAudioQueues.output.async {", "player.play(url, volume: volume, semitones: pitch)"], "sound queued",
      "every sound is played on the output queue")
pin(len(re.findall(r"(?<![\w.])play\(url, volume:", store)) == 2 and "playSound(" not in handle, "sound queued", "the store plays sounds only through play(_:volume:played:)")

# 3. The engine opens on the input queue; a press that was released meanwhile closes what opened, off the main actor.
pin("let opened = try await DictationAudioQueues.perform(on: DictationAudioQueues.input) {" in start and "next = opened.0" in start,
    "engine off main", "the press opens its engine through perform on the input queue")
opening = start[start.index("let opened = try await DictationAudioQueues.perform(on: DictationAudioQueues.input) {"):]
opening = opening[:opening.index("next = opened.0")]
pin(opening.count(".start(deviceID: deviceID)") == 2 and start.count(".start(deviceID:") == 2, "engine off main",
    "both engine starts (spare or fresh) run inside perform on the input queue")
order(opening, ["guard generation == attempt, !Task.isCancelled else {", "let orphan = opened.0", "DictationAudioQueues.input.async { _ = try? orphan.stop() }\n                    return"],
      "orphan closed", "an engine that opened after the press was released or canceled is closed, never left running")
spare = body(store, "    private func warmSpare() async {")
pin("built = try await DictationAudioQueues.perform(on: DictationAudioQueues.input) {" in spare
    and spare.index("DictationAudioQueues.perform(on: DictationAudioQueues.input)") < spare.index("try next.warm(deviceID: deviceID)")
    and spare.index("DictationAudioQueues.perform(on: DictationAudioQueues.input)") < spare.index("DictationAudioDevices.inputs()"),
    "engine off main", "a spare's list read and engine build run on the input queue")
pin(store.count("DictationAudioDevices.inputs()") == 2 and "    func refreshMicrophones() { microphones = DictationAudioDevices.inputs() }" in store,
    "engine off main", "the store reads the list itself only for Settings' Refresh (and a chosen microphone's cache miss)")

# 4. The start: quiet and the sound's numbers come back late; Accessibility for placement is off the main thread.
order(start, ['phase = "Listening"; pill = .listening(since: Date())', "heartbeat.listening(at: ProcessInfo.processInfo.systemUptime)",
              "playSound(.start) {", "quiet.begin(mode: quietMode, macRecording: macRecordingActive?() ?? false) {"],
      "pill first", "LISTENING is published before the sound and the mute are queued, so it never waits on them")
pin("quietNote = quiet.fallbackNote" not in store and "self?.quietNote = note" in start, "pill first",
    "the mute's fallback note arrives later; the start never reads the controller")
pin("DictationFocusedWindow.frame()" not in start and
    "(try? await DictationAudioQueues.perform(on: .global(qos: .userInitiated)) { DictationFocusedWindow.frame(lookup) }) ?? nil" in start,
    "placement off main", "the focused window is read from Accessibility off the main thread")
order(start, ["placing = Task { [weak self] in", "task = Task {", "await placing?.value", 'phase = "Listening"'], "placement off main",
      "LISTENING waits for the placement, never the main thread")
frame = body(d, "    static func frame(_ lookup: Lookup) -> CGRect? {")
pin("NSScreen" not in frame and "NSWorkspace" not in frame and "@MainActor" not in frame, "placement off main",
    "the Accessibility lookup touches no AppKit state, so it is safe off the main thread")

# 5. Learn from my edits reads the other app off the main actor.
watcher = body(d, "@MainActor final class DictationEditWatcher {")
pin("task = Task.detached(priority: .utility) { [weak self] in" in watcher and watcher.count("Task {") == 0, "edit watch off main",
    "the edit watch polls Accessibility off the main actor")
for name in ("measure(_ element: AXUIElement)", "text(_ element: AXUIElement, location: Int, length: Int)",
             "holdsFocus(_ element: AXUIElement, pid: Int32)", "secure(_ element: AXUIElement)"):
    pin(f"nonisolated static func {name}" in d, "edit watch off main", f"DictationInsertion.{name.split('(')[0]} is nonisolated")

# 6. The heartbeat: from the press, to three seconds after LISTENING, stopped on every way out.
beat = body(d, "@MainActor final class DictationMainHeartbeat {")
pin("RunLoop.main.add(timer, forMode: .common)" in beat and "Timer(timeInterval: Double(DictationStallMeter.tickMilliseconds) / 1000, repeats: true)" in beat
    and "if !meter.tick(ProcessInfo.processInfo.systemUptime) { timer.invalidate() }" in beat, "heartbeat",
    "a 16 ms timer on the main run loop in the common modes, stopping itself at the end")
order(start, ["let pressed = ProcessInfo.processInfo.systemUptime", "heartbeat.begin(at: pressed)", "generation = UUID()"], "heartbeat",
      "the heartbeat starts at the press itself")
close = body(store, "    private func closeMicrophone() {")
order(close, ["startMarks?.mainThreadStallMs = heartbeat.finish()", "timing?.include(startMarks)"], "heartbeat",
      "the captured dictation's line takes the stall")
pin("let stall = heartbeat.finish()" in body(store, "    private func fail(") and "_ = heartbeat.finish()" in body(store, "    func cancel() {")
    and "_ = heartbeat.finish()" in body(store, "    func interrupt() {"), "heartbeat", "a failure, cancel or interruption stops the heartbeat")

# 7. Census: every new off-main or timer site in MacDictation.swift was reviewed for isolation (0.5.328). A new one
# changes a count and needs the same review before the count is updated.
census = {r"DictationAudioQueues\.output\.async(?!After)": 5, r"DictationAudioQueues\.input\.async": 1, r"DictationAudioQueues\.perform\(": 3,
          r"DictationAudioQueues\.output\.asyncAfter": 1, r"Task\.detached": 3, r"\bTimer\(": 1}
# Task.detached, reviewed: the edit watch (0.5.328); the early polish start and its discard (0.5.329). Both 0.5.329 closures
# capture only Sendable values (the @Sendable bridge, the request, the box, the start's task), never self.
for needle, n in census.items():
    found = len(re.findall(needle, d))
    pin(found == n, "census", f"{needle} appears {found} times, reviewed {n}")

# 8. No layout thrash: the pill swaps inside the ledger's fixed slot, so the pet panel never resizes for it.
pin("let dictation = model.dictation" in pet and "private func dictationRouteChanged()" in pet, "no resize", "the pet's dictation observers are where they were")
resize = pet[pet.index("let dictation = model.dictation"):pet.index("private func dictationRouteChanged()")]
pin("$pill" not in resize and "$phase" not in resize and "$surface" not in resize, "no resize",
    "the pet panel resizes for a card, a list or a note, never for the pill or the phase")
# 9. 0.5.328 (Miles 2026-10-19 19:02:06, helper_failed:command_failed): the helper's refusal reaches the dictation whole.
helper = code(read("Sources/HelperClient.swift"))
model = code(read("Sources/ControllerModel.swift"))
pin('return try await model.runHelper(["mac-dictation"], timeout: 40, stdinData: audio, answers: true)' in app
    and "try await helper.run(arguments, timeout: timeout, stdinData: stdinData, answers: answers)" in model
    and "guard Self.returns(status: process.terminationStatus, ok: response.ok, answers: answers) else {" in helper
    and "nonisolated static func returns(status: Int32, ok: Bool, answers: Bool) -> Bool { status == 0 && (ok || answers) }" in helper,
    "refusal reaches dictation", "mac-dictation asks for the helper's own refusal, so noSpeech, reason and action are read, not a bare command_failed")
transcribe = body(store, "    private func transcribe(_ wav: Data, attempt: UUID) {")
pin('let noSpeech = response.details["noSpeech"]?.bool == true' in transcribe
    and "DictationFailReason.refused.code(reason)" in transcribe, "refusal reaches dictation",
    "a refusal is named on the timing line by the server's own reason code (whitelisted by DictationFailReason.code)")
print("PASS dictation smooth pins: mute, sounds and engines on their own queues, LISTENING never waits on them, placement and the edit watch off main, heartbeat on every path, callback census, no resize for the pill, helper refusals read whole")
