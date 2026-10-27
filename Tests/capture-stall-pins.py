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
store_src, app, core, capture_src, model_src, askcore = (code(p) for p in ("Sources/MacRecording.swift", "Sources/COSControlApp.swift", "Sources/MacRecordingCore.swift",
    "Sources/MacAudioCapture.swift", "Sources/ControllerModel.swift", "Sources/MeetingAskCore.swift"))
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
pin("self" not in writer, "writer off the main actor",
    "the writer closure never mentions self, so it cannot wait for the main actor")
pin("await MacRecordingWriter.run(stream: stream, spool: spool, captureId: id, progress: progress," in writer
    and "emit: { _ in } " not in writer and "emit: { _ = storedContinuation.yield($0) }" in writer,
    "store runs the core writer", "the store runs the same loop the checks run with the main thread blocked, and sends what it stores to the main actor")
pin(ordered(writer, "await MacRecordingWriter.run(", "storedContinuation.finish()"), "end of the writer ends the main actor's loop",
    "when the writer ends (stream finished or a chunk refused) the main actor's loop ends too")
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
pin(catch.count("watchdogTask?.cancel()") == 1 and ordered(catch, "guard startAttempt == attempt else { return }", "watchdogTask?.cancel(); watchdogTask = nil; stallLine = nil"),
    "stale start leaves the newer watchdog alone", "a start that was superseded and fails late returns before it can cancel the newer recording's watchdog")

# 3. The watchdog.
pin('phase = "recording"\n            startWatchdog(id: id, source: source)' in start, "watchdog starts when recording starts", "it runs only from the moment the recording is live")
tick = between(store, "    private func watchdogTick(", "    private func publishStall() {")
pin("guard phase == \"recording\", manifest?.captureId == id else { return }" in tick
    and "MacRecordingWatchdog.step(&watchdog, now: now, lastChunk: progress.lastWrite, restartInFlight: restartInFlight)" not in tick
    and "lastChunk: last, restartInFlight: restartInFlight)" in tick and "let now = Date(), last = progress.lastWrite" in tick,
    "watchdog reads the writer's progress", "the stall is judged from when the writer last stored a chunk, only while recording")
pin("stallLine = MacRecordingWatchdog.line(watchdog)" in tick, "watchdog line shown", "the panel line follows the watchdog state every look")
pin("MacRecordingBounded.run(seconds: TimeInterval(MacRecordingWatchdog.restartSeconds))" in tick, "restart is bounded", "a restart that hangs is given up on")
pin(ordered(tick, "if worked != true { watchdog.restartFailed() }", "publishStall()"), "failed restart is said",
    "a restart that fails or times out puts the Stop and save line up at once")
pin("restartInFlight = false" not in tick and ordered(tick, "restartInFlight = true", "tapGeneration += 1", "MacRecordingBounded.run(", "await self.restartReturned(generation: generation)", "return done"),
    "restart flag cleared only by the restart itself", "the in-flight flag is not cleared when the watchdog's time bound expires, only when the restart's own work returns (QA W3)")
returned = between(store, "    private func restartReturned(", "    private func restartTap(")
pin("if tapGeneration == generation { restartInFlight = false }" in returned, "a stale restart leaves the flag alone", "only the current restart clears the flag")
publish = between(store, "    private func publishStall() {", "    private func restartReturned(")
pin(ordered(publish, "stallLine = MacRecordingWatchdog.line(watchdog)", "watchdog.takeGiveUpNotice()", "MacRecordingWatchdog.notification(watchdog)", "stallNotice?(note.title, note.body)"),
    "one notification per stall", "an unrecovered stall posts its notification once, from the watchdog state's own once-only gate (QA W6)")
pin("macRecording.stallNotice = { [weak self] title, body in self?.meetingAudioNotifier.postRecordingStalled(title: title, body: body) }" in model_src
    and "func postRecordingStalled(title: String, body: String) {" in model_src, "notification reaches the app", "the stall notice goes through the existing meeting-audio notifier")
loop = between(store, "    private func startWatchdog(", "    private func watchdogTick(")
pin("UInt64(MacRecordingWatchdog.pollSeconds) * 1_000_000_000" in loop and "guard let progress else { return }" in loop, "watchdog cadence",
    "it looks once per chunk length, from the recording's own progress")
restart = between(store, "    private func restartTap(", "    private func installStopObservers() {")
pin(ordered(restart, "_ = await old.stop()", "makeEngine(", "engine.start(source: source)", "capture = engine"),
    "restart order", "the old tap is stopped (its tail is kept), then a new one started, then installed")
pin("guard generation == tapGeneration, phase == \"recording\", manifest?.captureId == id else { _ = await engine.stop(); return false }" in restart, "restart never outlives the recording",
    "a tap started after the recording stopped, or after a newer restart, is stopped again, never left running (QA W3)")
pin("guard generation == tapGeneration, phase == \"recording\", manifest?.captureId == id else { return false }" in restart and "func restartTap(id: String, source: MacAudioSource, generation: Int) async -> Bool {" in store,
    "stale restart does not start a tap", "a restart made stale while its old tap was stopping never starts a new one")
pin(ordered(finish, 'phase = "stopping"', "tapGeneration += 1", "MacRecordingOpenCaptures.shared.beginStopping(id)", "await MacRecordingTapStop.run({ await old.stop() })", "streamContinuation?.finish()"),
    "stop makes restarts stale and bounds the tap", "Stop invalidates a running restart, marks the capture as stopped by the person, then waits for the tap only within the bound (QA W2, W3, N5)")
pin('case .timedOut: recordingLog.error("stop: the tap did not stop in time code=tap_stop_timeout")' in finish and "case .stopped(let reason): if let reason { captureInterruption = reason }" in finish,
    "tap stop timeout logged by code", "a tap that does not stop in time is logged by a code only and Stop carries on")
pin("tapGeneration += 1" in start.split("installStopObservers()")[0], "a new recording starts a new generation", "a restart left over from the last recording can never act on this one")
pin(ordered(start, "recordingStartedAt = Date()", "let engine = makeEngine("), "recording start time taken", "the recording's own start is taken before its first tap")
engine_src = between(store, "    private func makeEngine(", "    private func takeStored(")
pin("}, recordingStartedAt: recordingStartedAt)" in engine_src, "every tap gets the recording's start", "the first tap and every restarted tap count the two-hour limit from the recording's own start (QA W4)")
pin("started = recordingStartedAt ?? now; lastInput = now" in capture_src and "guard !MacRecordingLimit.reached(startedAt: started) else {" in capture_src
    and "let recordingStartedAt: Date?" in capture_src, "tap counts from the recording's start", "the tap's two-hour limit reads the start it was given, not the moment it started")
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

# 5. The disk is not read on every redraw (QA W1).
pin("freeBytes: @autoclosure () -> Int64?) -> ParakeetRowState {" in askcore and "if let free = freeBytes(), free < requiredFreeBytes {" in askcore,
    "free space read only at the disk rule", "the Parakeet row asks for free space only at the one rule that needs it")
pin("freeBytes: freeBytes())" in askcore and "var freeBytes: () -> Int64? = { FreeSpaceReader.shared.value() }" in askcore,
    "free space read off the main thread", "the default reader answers from a cache and refreshes in the background")

print(f"capture stall pins: {passed} passed")
