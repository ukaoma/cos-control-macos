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

ROOT = Path(__file__).resolve().parent.parent
CORE, STORE, APP = "Sources/MacRecordingCore.swift", "Sources/MacRecording.swift", "Sources/COSControlApp.swift"

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
    ("C25 a finished capture stays registered", "core", CORE, "func remove(_ id: String) { lock.lock(); spools[id] = nil; lock.unlock() }", "func remove(_ id: String) { }"),
    # The wiring (pins lane).
    ("P1 the writer keeps the tap's own numbering", "pins", STORE, "let chunk = sequence.next(raw)", "let chunk = raw"),
    ("P2 the writer never reports progress", "pins", STORE, "sequence.stored(journal); progress.mark()", "sequence.stored(journal)"),
    ("P3 a stop does not wait for the writer", "pins", STORE, "        await writerTask?.value; writerTask = nil\n", ""),
    ("P4 a failed start does not wait for the writer", "pins", STORE, "streamContinuation?.finish(); await writerTask?.value; await chunksTask?.value", "streamContinuation?.finish(); await chunksTask?.value"),
    ("P5 the watchdog never starts", "pins", STORE, "            startWatchdog(id: id, source: source)\n", ""),
    ("P6 the restart is not bounded", "pins", STORE, "            let worked = await MacRecordingBounded.run(seconds: TimeInterval(MacRecordingWatchdog.restartSeconds)) { [weak self] in\n                await self?.restartTap(id: id, source: source) ?? false\n            }\n", "            let worked: Bool? = await self.restartTap(id: id, source: source)\n"),
    ("P7 a failed restart is not said", "pins", STORE, "if worked != true { watchdog.restartFailed(); stallLine = MacRecordingWatchdog.line(watchdog) }", "if false { watchdog.restartFailed(); stallLine = MacRecordingWatchdog.line(watchdog) }"),
    ("P8 the old tap keeps running", "pins", STORE, "        _ = await old.stop()\n", ""),
    ("P9 a restart can outlive the recording", "pins", STORE, "guard phase == \"recording\", manifest?.captureId == id else { _ = await engine.stop(); return false }", "guard true else { _ = await engine.stop(); return false }"),
    ("P10 the stall line hides behind older warnings", "pins", STORE, "        if let stall = stallLine { return stall }\n", ""),
    ("P11 a capture is never registered for the signal", "pins", STORE, "            MacRecordingOpenCaptures.shared.add(id, spool: spool)\n", ""),
    ("P12 a stopped capture stays registered", "pins", STORE, "            MacRecordingOpenCaptures.shared.remove(id)\n        }\n        phase = \"pending\"", "        }\n        phase = \"pending\""),
    ("P13 a failed start stays registered", "pins", STORE, "            MacRecordingOpenCaptures.shared.remove(id)\n            watchdogTask?.cancel(); watchdogTask = nil; stallLine = nil\n            let interruption", "            watchdogTask?.cancel(); watchdogTask = nil; stallLine = nil\n            let interruption"),
    ("P14 the signal never ends the process", "pins", STORE, "signal(SIGTERM, SIG_DFL); raise(SIGTERM)", "recordingLog.notice(\"sigterm handled\")"),
    ("P15 the app never installs the handler", "pins", APP, "        MacRecordingSigtermWiring.install()\n", ""),
    ("P16 a stop leaves the watchdog running", "pins", STORE, "        watchdogTask?.cancel(); watchdogTask = nil; stallLine = nil\n        // QA 0.5.313", "        // QA 0.5.313"),
    ("P17 an older stored manifest replaces a newer one", "pins", STORE, "        if current.chunks.count > journal.chunks.count { return }\n", ""),
    ("P18 the watchdog judges by the clock, not the writer", "pins", STORE, "let now = Date(), last = progress.lastWrite", "let now = Date(), last = Date()"),
]

def run(lane):
    if lane == "pins":
        return subprocess.run(["/usr/bin/python3", str(ROOT / "Tests/capture-stall-pins.py"), str(ROOT)], capture_output=True, text=True)
    for _ in range(40):   # exit 75 / "lock busy" / "refused" is a wait, never a kill
        r = subprocess.run(["zsh", str(ROOT / "Tests/run-mac-recording.sh")], cwd=ROOT, env=dict(os.environ, COS_MAC_REC_LANE="core"), capture_output=True, text=True)
        text = r.stdout + r.stderr
        if r.returncode == 75 or "lock busy" in text or "compile-bounded: refused" in text:
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
for lane in sorted({m[1] for m in chosen}):
    base = run(lane)
    if base.returncode != 0:
        print(f"BASELINE RED ({lane}):\n{base.stdout[-2000:]}{base.stderr[-2000:]}"); sys.exit(2)
    print(f"baseline green: {lane}: " + (base.stdout.strip().splitlines() or [""])[-1][:120])
killed = survivors = infra = 0
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
        if r.returncode != 0 and line:
            killed += 1; print(f"{name}: killed by {line}")
        elif r.returncode != 0:
            infra += 1; print(f"{name}: INFRASTRUCTURE (exit {r.returncode}, no named check)\n{out[-800:]}")
        else:
            survivors += 1; print(f"{name}: SURVIVED")
    finally:
        path.write_text(src)
        assert path.read_text() == src, f"restore failed for {rel}"
print(f"capture stall mutants: {killed} killed, {survivors} survived, {infra} infrastructure, of {len(chosen)}")
sys.exit(1 if survivors or infra else 0)
