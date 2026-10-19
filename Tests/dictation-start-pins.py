#!/usr/bin/env python3
"""0.5.327 truthful start: where DictationStart, DictationSpare, DictationStartMarks and DictationFailReason are wired.
Each failure names its behaviour as "pin failed [<behaviour>]". Code only: comments never satisfy a pin. The rules run
in MacDictationChecks; Tests/dictation-start-canary.py measures press to first buffer on this Mac's real microphone.

Miles, 2026-10-19: "when I click the dictation, the sound immediately happens ... But if I look at the pet, it doesn't
really start listening until like a second or so in." The start sound and LISTENING now wait for the first buffer.

    python3 Tests/dictation-start-pins.py <root>
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
    """Every needle present, in this order. A missing one fails the named pin, never a traceback."""
    pin(all(n in src for n in needles), behaviour, why)
    found = [src.index(n) for n in needles]
    pin(found == sorted(found), behaviour, why)


def at(src, needle, behaviour):
    pin(src.count(needle) == 1, behaviour, f"{needle!r} must appear exactly once (found {src.count(needle)})")
    return src.index(needle)


d = code(read("Sources/MacDictation.swift"))
start = body(d, "    func start() {")
task = at(start, "        task = Task {", "source shape")
press = start[:task]

# 1. The press itself is silent and says STARTING: no sound, no LISTENING, no mute before the microphone hears.
pin("pill = .starting" in press and "phase = \"Starting\"" in press, "starting on press", "the press shows STARTING")
pin("playSound(" not in press and "pill = .listening" not in press and "quiet.begin(" not in press, "nothing on press",
    "the press plays no sound, shows no LISTENING and builds no mute")
first = at(start, "switch await awaitFirstAudio(next, attempt: attempt) {", "first buffer")
arrived = at(start, "            case .arrived(let at):", "first buffer")
listening = at(start, 'phase = "Listening"; pill = .listening(since: Date())', "listening after first buffer")
sound = at(start, "            playSound(.start)", "sound after first buffer")
quiet = at(start, "            quiet.begin(mode: quietMode, macRecording: macRecordingActive?() ?? false)", "quiet after sound")
pin(task < first < arrived < listening, "listening after first buffer", "LISTENING only once the first buffer arrived")
pin(listening < sound, "sound after first buffer", "the start sound plays only after LISTENING, at the first buffer")
pin(sound < quiet, "quiet after sound", "the mute is built after the start sound is scheduled (COS is excluded, so it still plays)")
pin(d.count("pill = .listening(") == 1 and d.count('phase = "Listening"') == 1 and d.count("playSound(.start)") == 1,
    "one way to listen", "LISTENING and the start sound are set in exactly one place")

# 2. Waiting for the first buffer: superseded returns quietly; a failure or silence closes the microphone and says why.
wait = body(d, "    private func awaitFirstAudio(_ capture: DictationMicrophoneCapture, attempt: UUID) async -> DictationStart.FirstAudio {")
pin("while generation == attempt, !Task.isCancelled {" in wait and "if let at = capture.firstAudioUptime { return .arrived(at) }" in wait
    and "if ProcessInfo.processInfo.systemUptime >= deadline { return .timedOut }" in wait and "return .superseded" in wait,
    "first buffer wait", "the wait ends at the first audio, a failure, the deadline, or a newer dictation")
branch = start[first:arrived]
pin("case .superseded: return" in branch, "superseded", "a released or canceled start returns (cancel closed the microphone)")
order(branch, ["capture = nil; _ = try? next.stop()", "fail("], "mic closed on start failure",
      "a start that never heard closes the microphone before the card (no microphone left open)")
pin("DictationFailReason.noFirstBuffer" in branch and "DictationFailReason.microphoneFailed" in branch, "start fail codes",
    "silence and a microphone failure each name their code")

# 3. No microphone list on the press when none is chosen; a chosen one reads it only through DictationStart.resolve.
pin(start.count("refreshMicrophones()") == 1 and "enumerate: { refreshMicrophones(); return microphoneIDs })" in start,
    "no list on press", "the press reads the microphone list only inside DictationStart.resolve's enumerate")
pin("DictationStart.resolve(selectedUID: microphoneUID, cached: microphoneIDs, uidOf: { DictationAudioDevices.uid(of: $0) }," in start,
    "no list on press", "the press resolves the device from the cache and one UID read")
detached = at(start, "            if !microphoneUID.isEmpty {\n                Task { [weak self] in\n                    let list = await DictationAudioDevices.inputsOffMain()", "list after start")
pin("DictationAudioDevices.inputs()" not in start and detached > quiet
    and "    static func inputsOffMain() async -> [DictationMicrophone] { inputs() }" in body(d, "enum DictationAudioDevices {"), "list after start",
    "the list is refreshed off the main actor (a nonisolated async read), after listening began, and only for a chosen microphone")
core = code(read("Sources/MacDictationCore.swift"))
pin('guard !selectedUID.isEmpty else { return (.systemDefault, false) }' in body(core, "    static func resolve(selectedUID: String, cached: [String: AudioDeviceID], uidOf: (AudioDeviceID) -> String?,"), "no list on press",
    "no selection is the system default before any closure runs")

# 4. The spare engine: built off the press, never started there, taken once and checked.
warm = body(d, "    func warm(deviceID: AudioDeviceID?) throws {")
pin("start()" not in warm and "prepare()" not in warm and "installTap" not in warm, "spare never started",
    "warming builds the input node only; the microphone stays off")
pin(d.count(".warm(deviceID:") == 1 and ".warm(deviceID:" in body(d, "    private func warmSpare() {"), "spare never started",
    "only warmSpare warms an engine")
prep = body(d, "    func prepareSpare(after delay: Duration = .seconds(1)) {")
pin("guard let self, !Task.isCancelled, self.capture == nil, !self.busy else { return }" in prep, "spare only when idle",
    "a spare is built only while no microphone is open and nothing is dictating")
take = body(d, "    private func takeSpare(device: AudioDeviceID?) -> DictationMicrophoneCapture? {")
order(take, ["spare = nil", "DictationSpare.check(", "if case .discard"], "spare taken once",
      "the press takes the spare once and uses it only when the check passes")
pin(d.count("takeSpare(") == 2 and "(try? warm.start(deviceID: deviceID)) != nil" in start and "next = DictationMicrophoneCapture()" in start,
    "spare falls back", "a spare that will not start gives way to a fresh engine on the same press")
pin("guard let device = deviceID ?? DictationAudioDevices.defaultInput(),\n              DictationSpare.mayWarm(" in body(d, "    private func warmSpare() {"),
    "spare rules", "warming asks DictationSpare.mayWarm (allowed, enabled, not Bluetooth)")

# 5. The timing line: each start number is stamped where its step ends, and every failure names its code.
for field, after in [("pressToTaskMs", "task = Task {"), ("permissionMs", "default: permission = false"),
                     ("refreshMicsMs", "DictationStart.resolve("), ("engineStartMs", "capture = next"),
                     ("pressToFirstBufferMs", "case .arrived(let at):"), ("pressToSoundMs", "playSound(.start)"),
                     ("quietMs", "quiet.begin(")]:
    stamp = at(start, f"startMarks?.{field} = ", "timing fields")
    order(start, [after, f"startMarks?.{field} = "], "timing fields", f"{field} is stamped after its step ({after!r})")
pin("startMarks?.pressToFirstBufferMs = DictationStartMarks.ms(pressed, at)" in start, "timing fields",
    "the first-buffer time is the audio side's own stamp, not the moment the pill noticed")
close = body(d, "    private func closeMicrophone() {")
order(close, ["timing = DictationTiming.measure(", "timing?.include(startMarks)", "releaseMark = nil; startMarks = nil"],
      "timing fields", "the captured dictation's line takes the start numbers")
fail = body(d, "    private func fail(_ reason: String, code: String, card: Bool = true, action: DictationFailureAction? = nil) {")
order(fail, ["if timing == nil, let marks = startMarks { timing = DictationTiming.startFailure(marks, at: Date()) }",
             "timing?.failReason = code", 'recordTiming("failed")'], "fail reason",
    "a failure writes its code on the line, and a start failure writes a line of its own")
calls = [m.start() for m in re.finditer(r"(?<![\w.])fail\(", d) if not d[max(0, m.start() - 5):m.start()].endswith("func ")]


def arguments(src, open_paren):
    depth, i = 0, open_paren
    while True:
        depth += {"(": 1, ")": -1}.get(src[i], 0)
        if depth == 0:
            return src[open_paren:i + 1]
        i += 1


coded = [c for c in calls if re.search(r"\bcode: ", arguments(d, d.index("(", c)))]
pin(len(calls) == len(coded) == 9, "fail reason", f"every fail( call names its code ({len(coded)} of {len(calls)}, expected 9)")
pin("startMarks = nil" in body(d, "    func cancel() {") and "startMarks = nil" in body(d, "    func interrupt() {"), "timing fields",
    "cancel and interruptions drop the press's marks (they write no line)")
transcribe = body(d, "private func transcribe(_ wav: Data, attempt: UUID) {")
pin("fail(reason, code: Self.failCode(error)," in transcribe and "if let asked { timing?.transcribeMs = DictationStartMarks.ms(asked, ProcessInfo.processInfo.systemUptime) }" in transcribe,
    "fail reason", "a helper failure records how long it ran and which way it failed")

# 6. The pill: STARTING is an open ring and words, no level bars, no clock.
pill = body(d, "struct DictationListeningPill: View {")
order(pill, ["            case .starting:", "            case .listening(let since):"], "starting pill", "the pill has a STARTING case")
starting = pill[pill.index("            case .starting:"):pill.index("            case .listening(let since):")]
pin("liveBars" not in starting and "TimelineView" not in starting and "COSPalette.green" not in starting and "Text(pill.label)" in starting,
    "starting pill", "STARTING shows no bars, no clock and no green dot")
print("PASS dictation start pins: STARTING until the first buffer, then LISTENING, the sound and the mute; no microphone list on the press; spare never started; every start number and failure code on the timing line")
