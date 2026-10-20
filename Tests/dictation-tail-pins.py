#!/usr/bin/env python3
"""0.5.326 release tail: where DictationReleaseTail and DictationTiming are wired. Each failure names its behaviour as
"pin failed [<behaviour>]". Code only: comments never satisfy a pin. The rules run in MacDictationChecks; the real
engine canary (with and without the tail) is Tests/dictation-tail-canary.py, run by hand against a local server.

    python3 Tests/dictation-tail-pins.py <root>
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


d = code(read("Sources/MacDictation.swift"))

# 1. Which stops take the tail: the person's (hold released, toggle) do; the limit and a microphone failure do not.
pin("    func stop() { stop(ending: .released) }" in d, "person's stop", "stop() is the person's stop and takes the tail")
pin("if !Task.isCancelled { stop(ending: .maximum) }" in d, "limit", "the two-minute limit closes at once")
pin("if next.failure != nil { stop(ending: .failure); break }" in d, "failure", "a microphone failure closes at once")
pin(len(re.findall(r"\bstop\(\)", body(d, "    func hotKey(_ id: UInt32, down: Bool) {"))) == 2, "hotkeys",
    "the hold release and the toggle are the only hotkey stops")

# 2. The tail: listening goes on (no pill change), then the microphone closes for THIS dictation only.
tail = body(d, "    func stop(ending: DictationReleaseTail.Ending) {")
pin("let tail = DictationReleaseTail.tail(for: ending)" in tail and "tailing = true" in tail, "tail", "the tail length comes from the policy")
pin("try? await Task.sleep(for: .milliseconds(tail))" in tail
    and "guard let self, !Task.isCancelled, self.generation == attempt, self.tailing else { return }" in tail
    and tail.index("Task.sleep(for: .milliseconds(tail))") < tail.index("self.closeMicrophone()"),
    "tail current", "after the tail, the microphone closes only if this dictation is still the one tailing")
pin("pill" not in tail and "playSound" not in tail and "quiet.end" not in tail, "pill stays listening",
    "the release itself changes nothing visible or audible: the pill keeps listening through the tail")
pin("if tailing { if tail == 0 { closeMicrophone() }; return }" in tail, "limit mid-tail",
    "the limit or a failure during the tail closes at once; a second person's stop does nothing")
pin("releaseMark = (ProcessInfo.processInfo.systemUptime, capture.capturedBytes, tail)" in tail, "release mark",
    "the release time and byte mark are taken at the key up, not after the tail")

close = body(d, "    private func closeMicrophone() {")
pin(close.index("let pcm = try capture.stop()") < close.index("quiet.end()") < close.index("playSound(.stop)"), "order",
    "the microphone closes before other apps come back and before the stop sound (never recorded)")
pin("DictationTiming.measure(pcm: pcm, releaseBytes: mark.bytes, tailMs: mark.tailMs," in close, "timing", "the timing is measured from the closed PCM")

# 3. A press during the tail continues the same dictation; cancel and interruption end the tail.
hot = body(d, "    func hotKey(_ id: UInt32, down: Bool) {")
pin(hot.count("DictationReleaseTail.press(tailing: tailing, phase: phase) == .extend") == 2 and hot.count("extendTail()") == 2,
    "press during tail", "hold and toggle presses during the tail extend the same dictation")
ext = body(d, "    private func extendTail() {")
pin("tailing = false; tailTask?.cancel(); tailTask = nil; releaseMark = nil" in ext and "capture" not in ext and "start()" not in ext,
    "extend", "extending keeps the same capture running; it never starts a second dictation")
pin("tailing = false; tailTask?.cancel(); tailTask = nil; releaseMark = nil; timing = nil" in body(d, "    func cancel() {"),
    "cancel", "cancel ends the tail without transcribing")
pin("tailing = false; tailTask?.cancel(); tailTask = nil; releaseMark = nil; timing = nil" in body(d, "    func interrupt() {"),
    "interrupt", "an interruption during the tail closes at once and copies, as any interruption does")

# 4. The converter's held samples are kept, and nothing converts after the drain.
cap = body(d, "    func stop() throws -> Data {")
pin("converter?.finish(); converter = nil" in cap
    and cap.index("engine.inputNode.removeTap(onBus: 0)") < cap.index("converter?.finish(); converter = nil") < cap.index("return try pcm.result()"),
    "drain", "the converter drains after the tap is removed and before the PCM is read")
conv = body(d, "private final class DictationConverter: @unchecked Sendable {")
pin(conv.count("lock.lock(); defer { lock.unlock() }") == 2 and "guard !finished else { return }" in body(conv, "    func consume(_ input: AVAudioPCMBuffer) {")
    and "state.pointee = .endOfStream" in body(conv, "    func finish() {"), "drain lock",
    "finish and consume never overlap, and a late buffer after the drain is ignored")

# 5. One timing line per dictation, numbers only, in the log and the private JSONL file.
rec = body(d, "    private func recordTiming(_ outcome: String, line: DictationTiming? = nil) {")
logs = [l for l in rec.split("\n") if "dictationLog" in l]
pin(len(logs) == 1 and not re.search(r"\\\((text|heard|said|pcm|wav|response)\b", logs[0]), "no text", "the timing log line carries numbers only")
pin("polishMs = run.ms; polishModel = run.model.rawValue; polishOutcome = run.outcome.logName" in code(read("Sources/MacDictationCore.swift"))
    and "return DictationPolishRun(outcome: outcome, model: model, ms: elapsed," in body(d, "    private func polish(_ heard: String, attempt: UUID, showPill: Bool = true) async -> DictationPolishRun? {"),
    "polish timing", "the timing line records the polish model, outcome word and milliseconds")
pin("DictationTimingLog.append(finished, to: url)" in rec and "DictationTimingLog.fileName" in rec
    and "defaultHistoryURL()?.deletingLastPathComponent()" in rec, "file", "the JSONL lives beside the dictation history (a test home in checks)")
pin('if case .refused = outcome { recordTiming("copied") } else { recordTiming("typed") }' in body(d, "    private func finish(")
    and 'recordTiming("failed")' in body(d, "    private func fail("), "every outcome", "typed, copied and failed dictations each write one line")

core = code(read("Sources/MacDictationCore.swift"))
pin("static let milliseconds = 300" in core and "static let maximumBytes = 256 * 1024" in core, "constants", "a 300 ms tail and a 256 KB timing file")
print("PASS dictation tail pins: person's stop tails, limit and failure do not, press extends, drain after the tap, timing numbers only")
