#!/usr/bin/env python3
"""0.5.351 (mac_b0bd6732, 2026-10-26): where the capture stall fix is wired. The rules run in Tests/MacRecordingChecks.swift
(watchdog timing, the writer's sequence, the time bound, SIGTERM against a real signal); these pins prove the store, the
panel and the app call them. Comments are stripped, so an explanatory comment can never satisfy a pin. Each failure names
its behaviour as "FAILED: [<behaviour>]" for Tests/mutate-capture-stall.py.

    python3 Tests/capture-stall-pins.py <root>
"""
import pathlib, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
def code(rel):
    return "\n".join(l for l in (root / rel).read_text(encoding="utf-8").splitlines() if not l.lstrip().startswith("//"))
store_src, app, core = (code(p) for p in ("Sources/MacRecording.swift", "Sources/COSControlApp.swift", "Sources/MacRecordingCore.swift"))
passed = 0
def pin(ok, behaviour, why):
    global passed
    if not ok:
        sys.exit(f"FAILED: [{behaviour}] {why}")
    passed += 1
def ordered(text, *needles):
    """Every needle present, and in this order. A missing needle is a failed pin, never an exception."""
    at = -1
    for needle in needles:
        found = text.find(needle, at + 1)
        if found < 0:
            return False
        at = found
    return True
def between(text, start, end):
    pin(start in text and end in text.split(start, 1)[1], "source shape", f"cannot find {start!r} .. {end!r}")
    return text.split(start, 1)[1].split(end, 1)[0]

store = store_src.split("struct MacRecordingPanel: View {")[0]
start = between(store, "    private func start() async {", "    private func makeEngine(")
finish = between(store, "    private func finishStop() async {", "    private func hearingCheck(")
catch = start.split("        } catch {\n", 1)[1]
writer = between(start, "            writerTask = Task.detached(priority: .userInitiated) {", "            chunksTask = Task { [weak self] in")
consumer = between(start, "            chunksTask = Task { [weak self] in", "            let engine = makeEngine(")

# 1. The writer: its own executor, the journal's own sequence, progress for the watchdog, in that order.
pin("self" not in writer.replace("MacRecordingSequencer", ""), "writer off the main actor",
    "the writer closure never mentions self, so it cannot wait for the main actor")
pin("let chunk = sequence.next(raw)" in writer and "spool.append(chunk, captureId: id)" in writer and "sequence.stored(journal); progress.mark()" in writer
    and ordered(writer, "sequence.next(raw)", "spool.append(", "progress.mark()", "storedContinuation.yield("),
    "writer sequence", "each chunk takes the journal's next index, is stored, marks progress, then goes to the main actor")
pin("storedContinuation.yield(.init(failure: reason)); break" in writer and "storedContinuation.finish()" in writer.split("break")[-1],
    "writer failure and end", "a refused chunk is reported and ends the writer; the end of the stream ends the main actor's loop")
pin("for await event in stored {" in consumer and "for await" not in consumer.split("for await event in stored {", 1)[1], "main actor reads what was stored",
    "the main actor loop reads the writer's output, never the tap's stream")
pin("if let reason = event.failure { self.captureInterruption = reason; Task { await self.stop() }; break }" in consumer, "append failure stops",
    "a refused chunk stops the recording with its reason, as before")
pin("self.takeStored(journal)" in consumer, "stored manifest taken", "the panel's manifest follows the writer")
take = between(store, "    private func takeStored(", "    private func startWatchdog(")
pin("if current.chunks.count > journal.chunks.count { return }" in take and "next.acknowledged = max(next.acknowledged, current.acknowledged)" in take,
    "late note never moves the panel back", "an older stored manifest never replaces a newer one or lowers the acknowledged count")

# 2. Stop and a failed start wait for the writer before the journal is marked stopped.
pin(ordered(finish, "await writerTask?.value", "await chunksTask?.value", "markStopped(id)"), "stop waits for the writer",
    "every chunk the tap handed over is stored before the journal is marked stopped")
pin("await writerTask?.value; await chunksTask?.value" in catch, "failed start waits for the writer", "a start that fails also waits for the writer")
pin("watchdogTask?.cancel(); watchdogTask = nil; stallLine = nil" in finish and "watchdogTask?.cancel(); watchdogTask = nil; stallLine = nil" in catch,
    "watchdog stops with the recording", "stop and a failed start both end the watchdog and clear its line")

# 3. The watchdog.
pin('phase = "recording"\n            startWatchdog(id: id, source: source)' in start, "watchdog starts when recording starts", "it runs only from the moment the recording is live")
tick = between(store, "    private func watchdogTick(", "    private func restartTap(")
pin("guard phase == \"recording\", manifest?.captureId == id else { return }" in tick
    and "MacRecordingWatchdog.step(&watchdog, now: now, lastChunk: progress.lastWrite, restartInFlight: restartInFlight)" not in tick
    and "lastChunk: last, restartInFlight: restartInFlight)" in tick and "let now = Date(), last = progress.lastWrite" in tick,
    "watchdog reads the writer's progress", "the stall is judged from when the writer last stored a chunk, only while recording")
pin("stallLine = MacRecordingWatchdog.line(watchdog)" in tick, "watchdog line shown", "the panel line follows the watchdog state every look")
pin("MacRecordingBounded.run(seconds: TimeInterval(MacRecordingWatchdog.restartSeconds))" in tick, "restart is bounded", "a restart that hangs is given up on")
pin("if worked != true { watchdog.restartFailed(); stallLine = MacRecordingWatchdog.line(watchdog) }" in tick, "failed restart is said",
    "a restart that fails or times out puts the Stop and save line up at once")
pin(ordered(tick, "restartInFlight = true", "MacRecordingBounded.run(", "restartInFlight = false"),
    "one restart at a time", "no second restart starts while one runs")
loop = between(store, "    private func startWatchdog(", "    private func watchdogTick(")
pin("UInt64(MacRecordingWatchdog.pollSeconds) * 1_000_000_000" in loop and "guard let progress else { return }" in loop, "watchdog cadence",
    "it looks once per chunk length, from the recording's own progress")
restart = between(store, "    private func restartTap(", "    private func installStopObservers() {")
pin(ordered(restart, "_ = await old.stop()", "makeEngine(", "engine.start(source: source)", "capture = engine"),
    "restart order", "the old tap is stopped (its tail is kept), then a new one started, then installed")
pin("guard phase == \"recording\", manifest?.captureId == id else { _ = await engine.stop(); return false }" in restart, "restart never outlives the recording",
    "a tap started after the recording stopped is stopped again, never left running")
pin("continuation: continuation" in restart and "AsyncStream" not in restart.replace("streamContinuation", ""), "restart feeds the same stream",
    "the new tap writes to the same stream, so its chunks continue the same journal")
warn = between(store, "    var signalWarning: String? {", "    var canDiscard: Bool {")
pin(ordered(warn, "guard isRecording else { return nil }", "if let stall = stallLine { return stall }", "MacRecordingHearing.line("),
    "stall line wins the panel", "while recording, the stall line is the first warning the panel shows")

# 4. Open captures and SIGTERM.
pin(ordered(start, "manifest = initial\n", "MacRecordingOpenCaptures.shared.add(id, spool: spool)"), "capture registered once its journal exists",
    "a capture is registered for the signal handler as soon as its journal is written")
pin("MacRecordingOpenCaptures.shared.remove(id)" in catch and finish.count("MacRecordingOpenCaptures.shared.remove(id)") == 1
    and ordered(finish, "markStopped(id)", "MacRecordingOpenCaptures.shared.remove(id)"), "capture unregistered after it is stopped",
    "a stopped or failed capture leaves the registry; a stop unregisters only after the journal is marked")
wiring = between(store_src, "enum MacRecordingSigtermWiring {", "@MainActor extension COSAppDelegate {")
pin("source = MacRecordingSigterm.install { result in" in wiring and "signal(SIGTERM, SIG_DFL); raise(SIGTERM)" in wiring and "guard source == nil else { return }" in wiring,
    "sigterm handled, then ends as before", "the handler closes the journals, then lets the signal end the process")
pin("MacRecordingSigtermWiring.install()" in app, "sigterm installed at launch", "the app installs the handler where it wires the quit")
pin("signalNumber: Int32 = SIGTERM" in core, "default signal is SIGTERM", "the installed handler is for SIGTERM")
pin("static let waitSeconds: TimeInterval = 0.8" in core, "sigterm wait under a second", "the wait is bounded below one second")

print(f"capture stall pins: {passed} passed")
