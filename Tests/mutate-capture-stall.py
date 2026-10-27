#!/usr/bin/env python3
"""0.5.351: mutation gate for the capture-stall fix (watchdog, writer off the main actor, SIGTERM).

Runs the unmutated lanes first and refuses on any failure (a red baseline would "kill" every mutant). Each mutant must
match its target EXACTLY ONCE and is killed only when its lane fails with a NAMED check ("Precondition failed: <name>" from
Tests/MacRecordingChecks.swift, "FAILED: [<behaviour>]" from Tests/capture-stall-pins.py); a compile failure or any other
exit is an infrastructure error, not a kill. The core lane compiles MacRecordingCore.swift and its checks alone through
Tests/compile-guard.sh (waits on the shared lock, retries on exit 75); the pins lane compiles nothing.
Usage: python3 Tests/mutate-capture-stall.py [--list] [name-prefix...]
"""
import os, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import mutate_bounded as bounded

LIMIT = 900   # seconds per lane run; a mutant that deadlocks is killed after this and counts as a kill by timeout

ROOT = Path(__file__).resolve().parent.parent
CORE, STORE, APP = "Sources/MacRecordingCore.swift", "Sources/MacRecording.swift", "Sources/COSControlApp.swift"
CAPTURE, MODEL, ASK = "Sources/MacAudioCapture.swift", "Sources/ControllerModel.swift", "Sources/MeetingAskCore.swift"

MUTANTS = [
    # The rules (core lane).
    ("C1 the stall time is four chunk lengths", "core", CORE, "static var stallSeconds: Int { chunkSeconds * stallChunks }", "static var stallSeconds: Int { chunkSeconds * 4 }"),
    ("C2 the watchdog looks every second chunk", "core", CORE, "static var pollSeconds: Int { chunkSeconds }", "static var pollSeconds: Int { chunkSeconds * 2 }"),
    ("C3 the exact stall time is not yet a stall", "core", CORE, "guard now.timeIntervalSince(reference) >= TimeInterval(stallSeconds) else { return .none }", "guard now.timeIntervalSince(reference) > TimeInterval(stallSeconds) else { return .none }"),
    ("C4 a second restart starts while one runs", "core", CORE, "guard !state.gaveUp, !restartInFlight else { return .none }", "guard !state.gaveUp else { return .none }"),
    ("C5 the restart gets no time to work", "core", CORE, "let reference = max(lastChunk, state.restartAttemptAt ?? .distantPast)", "let reference = lastChunk"),
    ("C6 two restarts per stall", "core", CORE, "if state.attemptsThisStall < 1, state.totalRestarts < maxRestartsPerRecording {", "if state.attemptsThisStall < 2, state.totalRestarts < maxRestartsPerRecording {"),
    ("C7 one restart too many per recording", "core", CORE, "state.totalRestarts < maxRestartsPerRecording {", "state.totalRestarts <= maxRestartsPerRecording {"),
    ("C8 a chunk after the stall does not end it", "core", CORE, "if let since = state.stalledSince, lastChunk > since {", "if let since = state.stalledSince, lastChunk < since {"),
    ("C9 the stall is dated when it is noticed", "core", CORE, "if state.stalledSince == nil { state.stalledSince = lastChunk }", "if state.stalledSince == nil { state.stalledSince = now }"),
    ("C10 giving up is not remembered", "core", CORE, "        state.gaveUp = true\n        return .giveUp", "        return .giveUp"),
    ("C11 the restarting line says something else", "core", CORE, ". Restarting.\"", ". Recovering.\""),
    ("C12 the failure line promises the wrong thing", "core", CORE, "Stop and save keeps everything up to then.\"\n                            : ", "Stop and save everything up to then.\"\n                            : "),
    ("C13 a failed restart is not reported", "core", CORE, "mutating func restartFailed() { gaveUp = true }", "mutating func restartFailed() { }"),
    ("C14 progress can move backward", "core", CORE, "last = max(last, date)", "last = date"),
    ("C15 the writer keeps the tap's own index", "core", CORE, ".init(index: count, pcm: raw.pcm, endFrame: lastEnd + raw.pcm.count / 2, rawSignal: raw.rawSignal)", ".init(index: raw.index, pcm: raw.pcm, endFrame: lastEnd + raw.pcm.count / 2, rawSignal: raw.rawSignal)"),
    ("C16 the sequence forgets the journal's end", "core", CORE, "count = manifest.chunks.count; lastEnd = manifest.chunks.last?.endFrame ?? 0", "count = manifest.chunks.count; lastEnd = 0"),
    ("C17 exact zeros stop being exact zeros", "core", CORE, "pcm: Data(count: 2), endFrame: chunk.endFrame, rawSignal: false)", "pcm: Data(count: 2), endFrame: chunk.endFrame, rawSignal: true)"),
    ("C18 a hung operation is waited for", "core", CORE, "Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); once.resume(nil) }", "Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }"),
    ("C19 the signal waits longer than a second", "core", CORE, "static let waitSeconds: TimeInterval = 0.8", "static let waitSeconds: TimeInterval = 1.5"),
    ("C20 the signal flush has no real bound", "core", CORE, "let timedOut = group.wait(timeout: .now() + wait) == .timedOut", "let timedOut = group.wait(timeout: .now() + wait + 10) == .timedOut"),
    ("C21 the signal never marks the journal stopped", "core", CORE, "return (try? await spool.markStopped(id)) != nil", "return true"),
    ("C22 the signal says nothing about why", "core", CORE, "_ = try? await spool.interrupt(id, reason: MacRecordingSigterm.reason)", "_ = try? await spool.interrupt(id, reason: \"\")"),
    ("C23 the signal source never starts", "core", CORE, "        source.resume()\n        return source", "        return source"),
    ("C24 the signal closes nothing", "core", CORE, "finish(flush(ids: open.ids, wait: wait) { await open.closeForExit($0) })", "finish(flush(ids: [], wait: wait) { await open.closeForExit($0) })"),
    ("C25 a finished capture stays registered", "core", CORE, "func remove(_ id: String) { lock.lock(); spools[id] = nil; stopping.remove(id); lock.unlock() }", "func remove(_ id: String) { }"),
    # QA fixes (core lane: behaviour).
    ("C26 the writer keeps the tap's own numbering", "core", CORE, "            let chunk = sequence.next(raw)\n", "            let chunk = raw\n"),
    ("C27 the writer never reports progress", "core", CORE, "                sequence.stored(journal); progress.mark()\n                emit(", "                sequence.stored(journal)\n                emit("),
    ("C28 the writer reads on after a refused chunk", "core", CORE, "                emit(.init(failure: reason)); break", "                emit(.init(failure: reason))"),
    ("C29 the writer runs on the main actor", "core", CORE, "enum MacRecordingWriter {\n    static func run(", "enum MacRecordingWriter {\n    @MainActor static func run("),
    ("C30 the writer never logs a refusal", "core", CORE, "                log(reason)\n", ""),
    ("C31 Stop waits for a wedged tap", "core", CORE, "await MacRecordingBounded.run(seconds: seconds) { await stop() }", "await MacRecordingBounded.run(seconds: 3_600) { await stop() }"),
    ("C32 the tap stop bound is a minute", "core", CORE, "static let stopSeconds: TimeInterval = 5", "static let stopSeconds: TimeInterval = 60"),
    ("C33 a timed out tap stop looks stopped", "core", CORE, "guard let answer else { return .timedOut }", "guard let answer else { return .stopped(nil) }"),
    ("C34 the two-hour limit is one second late", "core", CORE, "now.timeIntervalSince(startedAt) >= pilotSeconds", "now.timeIntervalSince(startedAt) > pilotSeconds"),
    ("C35 the pilot limit is shorter", "core", CORE, "static let pilotSeconds: TimeInterval = 7_200", "static let pilotSeconds: TimeInterval = 7_000"),
    ("C36 the notice posts more than once", "core", CORE, "            noticePosted = true; return true", "            return true"),
    ("C37 the notice posts before giving up", "core", CORE, "guard gaveUp, stalledSince != nil, !noticePosted else { return false }", "guard stalledSince != nil, !noticePosted else { return false }"),
    ("C38 the next stall never posts", "core", CORE, "            state.noticePosted = false\n", ""),
    ("C39 the notice body is not the panel line", "core", CORE, "return (\"Mac recording not receiving audio\", text)", "return (\"Mac recording not receiving audio\", \"Stalled\")"),
    ("C40 a quit reads as an incomplete recording", "core", CORE, "if reason == MacRecordingSigterm.reason { return (MacRecordingSigterm.reason, false) }", "if reason == MacRecordingSigterm.reason { return (MacRecordingSigterm.reason, true) }"),
    ("C41 the quit copy claims what was recorded", "core", CORE, "Everything saved up to then is kept.\"\n    struct Result", "Everything recorded up to then is kept.\"\n    struct Result"),
    ("C42 a stop the person made reads as a quit", "core", CORE, "if !isStopping(id) { _ = try? await spool.interrupt(id, reason: MacRecordingSigterm.reason) }", "_ = try? await spool.interrupt(id, reason: MacRecordingSigterm.reason)"),
    ("C43 the stopping mark outlives its capture", "core", CORE, "spools[id] = nil; stopping.remove(id); lock.unlock()", "spools[id] = nil; lock.unlock()"),
    ("C44 an unknown capture can be marked stopping", "core", CORE, "func beginStopping(_ id: String) { lock.lock(); if spools[id] != nil { stopping.insert(id) }; lock.unlock() }", "func beginStopping(_ id: String) { lock.lock(); stopping.insert(id); lock.unlock() }"),
    # QA W1 (transcription lane: behaviour of the free-space read, compiles MeetingAskCore and its checks).
    ("T1 the store reads the disk before it knows it needs it", "trans", ASK, "return Transcription.parakeetState(settings, installing: installing, recording: recording, freeBytes: freeBytes())", "let eager = freeBytes(); return Transcription.parakeetState(settings, installing: installing, recording: recording, freeBytes: eager)"),
    ("T2 the Parakeet rule reads the disk for every row", "trans", ASK, "let parakeet = settings.parakeet\n        if installing || parakeet.serverInstalling { return .installing(progressLine(parakeet)) }", "let parakeet = settings.parakeet; _ = freeBytes()\n        if installing || parakeet.serverInstalling { return .installing(progressLine(parakeet)) }"),
    ("T3 the reader's first call waits for the disk", "trans", ASK, "        return cached\n    }\n    /// For checks: waits", "        if cached == nil { Thread.sleep(forTimeInterval: 0.6) }\n        return cached\n    }\n    /// For checks: waits"),
    ("T4 the reader reads again on every call", "trans", ASK, "let stale = readAt.map { now().timeIntervalSince($0) >= ttl } ?? true", "let stale = readAt.map { now().timeIntervalSince($0) >= 0 } ?? true"),
    ("T5 the reader never refreshes", "trans", ASK, "let stale = readAt.map { now().timeIntervalSince($0) >= ttl } ?? true", "let stale = readAt.map { now().timeIntervalSince($0) >= 1e12 } ?? true"),
    # QA2 fixes: the rules (core lane) and the wiring (pins lane).
    ("C45 a stall notice is never taken back", "core", CORE, "            if state.noticePosted { state.noticeToRemove = true }\n", ""),
    ("C46 a taken-back notice is taken back again", "core", CORE, "            noticeToRemove = false; return true", "            return true"),
    ("C47 a stall that posted nothing takes a notice back", "core", CORE, "            if state.noticePosted { state.noticeToRemove = true }\n", "            state.noticeToRemove = true\n"),
    ("C48 Keep and Retry wait a minute for a running delivery", "core", CORE, "static let detachSeconds: Double = 2", "static let detachSeconds: Double = 60"),
    ("P35 a late tick speaks for another recording", "pins", STORE, "            guard startAttempt == attempt, phase == \"recording\", manifest?.captureId == id else { return }\n", ""),
    ("P36 the tick forgets which recording it began in", "pins", STORE, "        let attempt = startAttempt\n", "        let attempt: UUID? = nil\n"),
    ("P37 a leaked tap can stop a later recording", "pins", STORE, "guard let self, self.manifest?.captureId == id, [\"starting\", \"recording\"].contains(self.phase) else {", "guard let self else {"),
    ("P38 a leaked tap can stop a recording being saved", "pins", STORE, "self.manifest?.captureId == id, [\"starting\", \"recording\"].contains(self.phase) else {", "self.manifest?.captureId == id, [\"starting\", \"recording\", \"stopping\", \"pending\"].contains(self.phase) else {"),
    ("P39 the stall notice stays when audio returns", "pins", STORE, "        if watchdog.takeClearedNotice() { stallCleared?(capture) }\n", ""),
    ("P40 the stall notice outlives Stop", "pins", STORE, "        if watchdog.noticePosted, let id = manifest?.captureId { stallCleared?(id) }\n", ""),
    ("P41 every stall notice is a new one", "pins", MODEL, "let identifier = \"mac-recording-stalled-\\(captureId)\"", "let identifier = \"mac-recording-stalled-\\(UUID().uuidString)\""),
    # The wiring (pins lane).
    ("P3 a stop does not wait for the writer", "pins", STORE, "        await writerTask?.value; writerTask = nil\n", ""),
    ("P4 a failed start does not wait for the writer", "pins", STORE, "streamContinuation?.finish(); await writerTask?.value; await chunksTask?.value", "streamContinuation?.finish(); await chunksTask?.value"),
    ("P5 the watchdog never starts", "pins", STORE, "            startWatchdog(id: id, source: source)\n", ""),
    ("P6 the restart is not bounded", "pins", STORE, "            let worked = await MacRecordingBounded.run(seconds: TimeInterval(MacRecordingWatchdog.restartSeconds)) { [weak self] in\n                guard let self else { return false }\n                let done = await self.restartTap(id: id, source: source, generation: generation)\n                await self.restartReturned(generation: generation)\n                return done\n            }\n", "            let worked: Bool? = await self.restartTap(id: id, source: source, generation: generation)\n            restartReturned(generation: generation)\n"),
    ("P7 a failed restart is not said", "pins", STORE, "if worked != true { watchdog.restartFailed() }", "if false { watchdog.restartFailed() }"),
    ("P8 the old tap keeps running", "pins", STORE, "        _ = await old.stop()\n", ""),
    ("P9 a restart can outlive the recording", "pins", STORE, "guard generation == tapGeneration, phase == \"recording\", manifest?.captureId == id else { _ = await engine.stop(); return false }", "guard true else { _ = await engine.stop(); return false }"),
    ("P10 the stall line hides behind older warnings", "pins", STORE, "        if let stall = stallLine { return stall }\n", ""),
    ("P11 a capture is never registered for the signal", "pins", STORE, "            MacRecordingOpenCaptures.shared.add(id, spool: spool)\n", ""),
    ("P12 a stopped capture stays registered", "pins", STORE, "            MacRecordingOpenCaptures.shared.remove(id)\n        }\n        phase = \"pending\"", "        }\n        phase = \"pending\""),
    ("P13 a failed start stays registered", "pins", STORE, "            MacRecordingOpenCaptures.shared.remove(id)\n            let interruption", "            let interruption"),
    ("P14 the signal never ends the process", "pins", STORE, "signal(SIGTERM, SIG_DFL); raise(SIGTERM)", "recordingLog.notice(\"sigterm handled\")"),
    ("P15 the app never installs the handler", "pins", APP, "        MacRecordingSigtermWiring.install()\n", ""),
    ("P16 a stop leaves the watchdog running", "pins", STORE, "        watchdogTask?.cancel(); watchdogTask = nil; stallLine = nil\n        if watchdog.noticePosted", "        if watchdog.noticePosted"),
    ("P17 an older stored manifest replaces a newer one", "pins", STORE, "        if current.chunks.count > journal.chunks.count { return }\n", ""),
    ("P18 the watchdog judges by the clock, not the writer", "pins", STORE, "let now = Date(), last = progress.lastWrite", "let now = Date(), last = Date()"),
    # QA fixes (pins lane: wiring the store cannot run without the app).
    ("P19 the restart flag is cleared when the bound expires", "pins", STORE, "            recordingLog.notice(\"watchdog: restart \\(worked == true", "            restartInFlight = false\n            recordingLog.notice(\"watchdog: restart \\(worked == true"),
    ("P20 a stale restart installs a new tap", "pins", STORE, "guard generation == tapGeneration, phase == \"recording\", manifest?.captureId == id else { return false }", "guard phase == \"recording\", manifest?.captureId == id else { return false }"),
    ("P21 Stop does not make a running restart stale", "pins", STORE, "        phase = \"stopping\"\n        tapGeneration += 1\n", "        phase = \"stopping\"\n"),
    ("P22 Stop does not mark the capture as stopped by the person", "pins", STORE, "        if let id = manifest?.captureId { MacRecordingOpenCaptures.shared.beginStopping(id) }\n", ""),
    ("P23 Stop waits for the tap with no bound", "pins", STORE, "switch await MacRecordingTapStop.run({ await old.stop() }) {", "switch MacRecordingTapStop.Outcome.stopped(await old.stop()) {"),
    ("P24 a restarted tap counts the limit from its own start", "pins", STORE, "        }, recordingStartedAt: recordingStartedAt)", "        })"),
    ("P25 the recording's start is never taken", "pins", STORE, "            recordingStartedAt = Date()\n", ""),
    ("P26 the tap ignores the start it was given", "pins", CAPTURE, "started = recordingStartedAt ?? now; lastInput = now", "started = now; lastInput = now"),
    ("P27 the tap's limit ignores the shared rule", "pins", CAPTURE, "guard !MacRecordingLimit.reached(startedAt: started) else {", "guard Date().timeIntervalSince(started) < 7_200 else {"),
    ("P28 an unrecovered stall posts no notification", "pins", STORE, "{ stallNotice?(capture, note.title, note.body) }", "{ _ = note }"),
    ("P29 the stall line and notice are not published after a restart", "pins", STORE, "            if worked != true { watchdog.restartFailed() }\n        }\n        publishStall()\n", "            if worked != true { watchdog.restartFailed() }\n        }\n"),
    ("P30 a late failing start cancels the newer watchdog", "pins", STORE, "            MacRecordingOpenCaptures.shared.remove(id)\n            let interruption", "            MacRecordingOpenCaptures.shared.remove(id)\n            watchdogTask?.cancel(); watchdogTask = nil; stallLine = nil\n            let interruption"),
    ("P31 the app does not post the stall notice", "pins", MODEL, "        macRecording.stallNotice = { [weak self] captureId, title, body in self?.meetingAudioNotifier.postRecordingStalled(captureId: captureId, title: title, body: body) }\n", ""),
    ("P32 the Parakeet row reads the disk eagerly", "pins", ASK, "freeBytes: @autoclosure () -> Int64?) -> ParakeetRowState {", "freeBytes: Int64?) -> ParakeetRowState {"),
    ("P33 the free space is read on the calling thread", "pins", ASK, "var freeBytes: () -> Int64? = { FreeSpaceReader.shared.value() }", "var freeBytes: () -> Int64? = { (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage }"),
    ("P34 the store runs its own writer loop", "pins", STORE, "                await MacRecordingWriter.run(stream: stream, spool: spool, captureId: id, progress: progress,", "                await MacRecordingWriterX.run(stream: stream, spool: spool, captureId: id, progress: progress,"),
]

def run(lane):
    if lane == "pins":
        return bounded.run(["/usr/bin/python3", str(ROOT / "Tests/capture-stall-pins.py"), str(ROOT)], 60)
    if lane == "trans":
        for _ in range(40):
            r = bounded.run(["zsh", str(ROOT / "Tests/run-transcription-settings.sh")], LIMIT, cwd=ROOT)
            text = r.stdout + r.stderr
            if r.returncode == 75 or "lock busy" in text or "compile-bounded: stopped" in text or "compile-bounded: refused" in text:
                time.sleep(60); continue
            return r
        return r
    for _ in range(40):   # exit 75 / "lock busy" / "refused" is a wait, never a kill
        r = bounded.run(["zsh", str(ROOT / "Tests/run-mac-recording.sh")], LIMIT, cwd=ROOT, env=dict(os.environ, COS_MAC_REC_LANE="core"))
        text = r.stdout + r.stderr
        if r.returncode == 75 or "lock busy" in text or "compile-bounded: stopped" in text or "compile-bounded: refused" in text:
            time.sleep(60); continue
        return r
    return r

def named(out):
    for line in out.splitlines():
        if "Precondition failed" in line or "FAILED: [" in line:
            return line.strip()[:220]
    return None

args = [a for a in sys.argv[1:] if not a.startswith("--")]
if "--list" in sys.argv:
    for m in MUTANTS: print(m[0])
    sys.exit(0)
chosen = [m for m in MUTANTS if not args or any(m[0].startswith(a) for a in args)]
_sha = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
_dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain"], capture_output=True, text=True).stdout.strip().splitlines()
print(f"gate header: mutate-capture-stall.py sha={_sha} dirty_files={len(_dirty)} started={time.strftime('%Y-%m-%d %H:%M:%S %Z')} per-mutant limit={LIMIT}s", flush=True)
for lane in sorted({m[1] for m in chosen}):
    base = run(lane)
    if base.returncode != 0:
        print(f"BASELINE RED ({lane}):\n{base.stdout[-2000:]}{base.stderr[-2000:]}"); sys.exit(2)
    print(f"baseline green: {lane}: " + (base.stdout.strip().splitlines() or [""])[-1][:120])
killed = survivors = infra = timeouts = 0
for name, lane, rel, old, new in chosen:
    path = ROOT / rel
    src = path.read_text()
    if src.count(old) != 1 or old == new:
        print(f"{name}: NOT APPLIED (target found {src.count(old)} times)"); infra += 1; continue
    path.write_text(src.replace(old, new))
    try:
        r = run(lane)
        out = r.stdout + r.stderr
        line = named(out)
        if getattr(r, "timed_out", False):
            killed += 1; timeouts += 1; print(f"{name}: killed by TIMEOUT after {LIMIT} s (the mutant hangs; no named check)")
        elif r.returncode != 0 and line:
            killed += 1; print(f"{name}: killed by {line}")
        elif r.returncode != 0:
            infra += 1; print(f"{name}: INFRASTRUCTURE (exit {r.returncode}, no named check)\n{out[-800:]}")
        else:
            survivors += 1; print(f"{name}: SURVIVED")
    finally:
        path.write_text(src)
        assert path.read_text() == src, f"restore failed for {rel}"
print(f"capture stall mutants: {killed} killed ({timeouts} by timeout), {survivors} survived, {infra} infrastructure, of {len(chosen)}")
sys.exit(1 if survivors or infra else 0)
