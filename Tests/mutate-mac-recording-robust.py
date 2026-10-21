#!/usr/bin/env python3
"""0.5.334: mutation gate for the Record on Mac hearing check, fail-fast and Discard (Miles 2026-10-21 13:15).

Runs the unmutated lanes first and refuses on any failure (a red baseline would "kill" every mutant). Then each mutant
must match its target EXACTLY ONCE, and is killed only when its lane fails with a NAMED check ("Precondition failed: <name>"
from Tests/MacRecordingChecks.swift, "FAILED: [<behaviour>]" from the pins, or "AssertionError: <label>" from the helper
checks); a compile failure is an infrastructure error, not a kill. Every lane compiles through Tests/compile-guard.sh,
one at a time, and the core lane is MacRecordingCore.swift alone (never a full COS Control compile).
Usage: python3 Tests/mutate-mac-recording-robust.py [--list] [name-prefix...]
"""
import os, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE, STORE, CAP, MODEL, MEET, APP, HELPER = ("Sources/MacRecordingCore.swift", "Sources/MacRecording.swift", "Sources/MacAudioCapture.swift",
    "Sources/ControllerModel.swift", "Sources/ActivityMeetings.swift", "Sources/COSControlApp.swift", "HelperSources/main.swift")

MUTANTS = [
    # The rules (core lane: Tests/MacRecordingChecks.swift runs them).
    ("H1 a quiet sample below one Int16 step reads as zero", "core", CORE, "for sample in samples where sample != 0 { return true }", "for sample in samples where abs(sample) >= 1.0 / 32768 { return true }"),
    ("H2 digital silence ignores the raw flag", "core", CORE, "var digitalSilence: Bool { !rawSignal && MacRecordingSignal.isDigitalZero(pcm) }", "var digitalSilence: Bool { MacRecordingSignal.isDigitalZero(pcm) }"),
    ("H3 any sound does not end the fail-fast", "core", CORE, "guard allMacAudio, !state.heardSignal, othersPlaying != false else { return .keep }", "guard allMacAudio, othersPlaying != false else { return .keep }"),
    ("H4 the fail-fast ignores whether anything plays", "core", CORE, "guard allMacAudio, !state.heardSignal, othersPlaying != false else { return .keep }", "guard allMacAudio, !state.heardSignal else { return .keep }"),
    ("H5 the fail-fast fires for a per-app source", "core", CORE, "guard allMacAudio, !state.heardSignal, othersPlaying != false else { return .keep }", "guard !state.heardSignal, othersPlaying != false else { return .keep }"),
    ("H6 one zero chunk is enough", "core", CORE, "    static let failFastChunks = 2\n", "    static let failFastChunks = 1\n"),
    ("H7 sound does not mark heard", "core", CORE, "guard digitalSilence else { state.heardSignal = true; state.suspect = false; state.zeroChunksWhilePlaying = 0; return .keep }", "guard digitalSilence else { state.suspect = false; state.zeroChunksWhilePlaying = 0; return .keep }"),
    ("H8 the probe warns with nothing playing", "core", CORE, "state.suspect = allMacAudio && !state.heardSignal && othersPlaying != false", "state.suspect = allMacAudio && !state.heardSignal"),
    ("H9 the probe warning outlives the recording", "core", CORE, "recording && state.suspect && !state.heardSignal ? suspectLine : nil", "state.suspect && !state.heardSignal ? suspectLine : nil"),
    ("H10 the no-sound stop reads as an incomplete recording", "core", CORE, "        if reason == MacRecordingHearing.cannotHearMessage { return (\"Mac recording stopped\", MacRecordingHearing.notificationBody) }\n", ""),
    ("D1 Keep is offered for no speech", "core", CORE, "paused && !noSpeech && pending && stopped && !delivering", "(paused || noSpeech) && pending && stopped && !delivering"),
    ("D2 Discard offered while delivering", "core", CORE, "(noSpeech || allZero) && pending && stopped && !delivering", "(noSpeech || allZero) && pending && stopped"),
    ("D3 Discard not offered for local zeros", "core", CORE, "(noSpeech || allZero) && pending && stopped && !delivering", "noSpeech && pending && stopped && !delivering"),
    ("D4 Retry offered for no speech", "core", CORE, "pending && hasChunks && !noSpeech && !allZero", "pending && hasChunks && !allZero"),
    ("D5 a stranded row still transcribing offers Discard", "core", CORE, "sessionId.hasPrefix(\"mac_\") && !canSave && transcriptState == \"no_speech\"", "sessionId.hasPrefix(\"mac_\") && !canSave"),
    ("D6 an older server reads as discarded", "core", CORE, "case nil: return httpStatus == 404 ? .unsupported : .unreachable", "case nil: return httpStatus == 404 ? .absent : .unreachable"),
    ("D7 an older server's note hides that its copy stays", "core", CORE, "        case .unsupported: return local + \" This COS server is older and keeps its copy until its own clean-up; update the server to clear it now.\"\n", "        case .unsupported: return local\n"),
    ("D8 a pre-0.5.334 journal reads as silent", "core", CORE, "next.heardSignal = (value.chunks.isEmpty ? false : (value.heardSignal ?? true)) || !chunk.digitalSilence", "next.heardSignal = (value.chunks.isEmpty ? false : (value.heardSignal ?? false)) || !chunk.digitalSilence"),
    ("D9 one silent chunk after sound forgets the sound", "core", CORE, "next.heardSignal = (value.chunks.isEmpty ? false : (value.heardSignal ?? true)) || !chunk.digitalSilence", "next.heardSignal = !chunk.digitalSilence"),
    ("D10 a second discard of the same name overwrites", "core", CORE, "        if fstatat(target, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { name = id + \".\" + String(Int(date.timeIntervalSince1970)) }\n", ""),
    ("D11 the server is asked though the local move failed", "core", CORE, "catch { return Outcome(captureId: captureId, moved: nil, localError: error.localizedDescription, server: .unreachable) }", "catch { _ = await server(captureId, serverInstanceId); return Outcome(captureId: captureId, moved: nil, localError: error.localizedDescription, server: .unreachable) }"),
    ("D12 an older server is asked anyway", "core", CORE, "let answer = serverSupported ? await server(captureId, serverInstanceId) : .unsupported", "let answer = await server(captureId, serverInstanceId)"),
    ("D13 a Glasses session ends its hand-off", "core", CORE, "sessionId.hasPrefix(\"mac_\") && noMeeting.contains(sessionId)", "noMeeting.contains(sessionId)"),
    ("D14 the discarded folder is not owner only", "core", CORE, "let target = try directoryFD(day, create: true); defer { Darwin.close(target) }", "try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true); let target = Darwin.open(day.path, O_RDONLY | O_DIRECTORY); defer { Darwin.close(target) }"),
    # The wiring (pins lane).
    ("W1 the zero test reads the resampled Int16", "pins", CAP, "            if !rawSignalSinceChunk, MacRecordingSignal.hasRawSignal(UnsafeBufferPointer(start: data, count: raw.count / 4)) {\n                rawSignalSinceChunk = true; rawSignalEver = true\n            }\n", ""),
    ("W2 the chunk flag never resets", "pins", CAP, "                let signal = rawSignalSinceChunk; rawSignalSinceChunk = false\n", "                let signal = rawSignalSinceChunk\n"),
    ("W3 the store delivers before checking", "pins", STORE, "                        if await self.hearingCheck(chunk, allMacAudio: source.isAllMacAudio) == .cannotHear {\n                            Task { await self.stopCannotHear(id) }; break\n                        }\n                        self.deliverPending()", "                        self.deliverPending()\n                        if await self.hearingCheck(chunk, allMacAudio: source.isAllMacAudio) == .cannotHear {\n                            Task { await self.stopCannotHear(id) }; break\n                        }"),
    ("W4 the fail-fast keeps recording", "pins", STORE, "                            Task { await self.stopCannotHear(id) }; break\n", "                            recordingLog.error(\"cannot hear\")\n"),
    ("W5 the zeros are delivered for saving", "pins", STORE, "        if !failFast { deliverPending() }\n", "        deliverPending()\n"),
    ("W6 the fail-fast leaves the capture pending", "pins", STORE, "        await stop()\n        await discardNoSound(cannotHear: true)\n", "        await stop()\n"),
    ("W7 the panel discards without a confirm", "pins", STORE, "Button(MacRecordingDiscard.buttonTitle) { confirmDiscard = true }", "Button(MacRecordingDiscard.buttonTitle) { Task { await store.discardNoSound() } }"),
    ("W8 Retry saving is back for no speech", "pins", STORE, "                        if store.canRetrySave {\n                            Button(\"Retry saving retained audio\") { store.deliverPending() }\n                        }", "                        Button(\"Retry saving retained audio\") { store.deliverPending() }"),
    ("W9 delivery restarts during a discard", "pins", STORE, "        guard phase != \"discarding\" else { return }\n", ""),
    ("W10 no speech keeps the red dead-end line", "pins", STORE, "                if self.noSpeech { self.noMeetingCaptureIDs.insert(id); self.error = nil }\n                else { self.error =", "                do { self.error ="),
    ("W11 the stranded row keeps a Save that cannot work", "pins", MEET, "                    if MacRecordingDiscard.strandedOffersDiscard(sessionId: capture.sessionId, transcriptState: capture.transcriptState, canSave: capture.canSave) {", "                    if false {"),
    ("W12 the hand-off still looks for a meeting", "pins", MODEL, "            if found == nil, MacRecordingNoMeeting.endsHandoff(sessionId: id, noMeeting: macRecording.noMeetingCaptureIDs) { feed.phase = .ended }\n", ""),
    ("W13 a no-sound capture pins a Live now row", "pins", MODEL, ".filter { !MacRecordingNoMeeting.endsHandoff(sessionId: $0.sessionId, noMeeting: noMeeting) }", ""),
    ("W14 Open System Settings asks without the pane", "pins", APP, "await model?.requestSystemAudio(for: \"All Mac audio\", wantsPane: true) }", "await model?.requestSystemAudio(for: \"All Mac audio\") }"),
    ("W15 the server capability is never read", "pins", STORE, "                    serverDiscard = result[\"discard\"]?.bool == true\n", ""),
    # The helper (helper lane: the compiled helper against the loopback stand-in).
    ("X1 the helper discards without confirm", "helper", HELPER, "            guard payload[\"confirm\"] as? Bool == true, (payload[\"confirm\"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else {", "            guard true else {"),
    ("X2 the helper takes a number for confirm", "helper", HELPER, "            guard payload[\"confirm\"] as? Bool == true, (payload[\"confirm\"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else {", "            guard payload[\"confirm\"] as? Bool == true else {"),
    ("X3 an older server's 404 has no reason", "helper", HELPER, "            else if operation == \"discard\", response.status == 404 { failure[\"reason\"] = \"route_absent\" }\n", ""),
]

def run(lane, root):
    # compile-bounded refuses (exit 75) while the Mac lacks memory headroom; that is a wait, never a kill.
    import time
    for _ in range(20):
        r = run_once(lane, root)
        if r.returncode == 75 or "compile-bounded: refused" in (r.stdout + r.stderr):
            time.sleep(60); continue
        return r
    return r

def run_once(lane, root):
    if lane == "helper":
        out = tempfile.mkdtemp(prefix="cos-mac-rec-helper-", dir="/private/tmp")
        # The helper exactly as Tests/run.sh builds it.
        build = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), str(root / "Tests/compile-guard.sh"), "swiftc",
            "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete",
            str(root / "HelperSources/main.swift"), str(root / "HelperSources/ProviderStatusCore.swift"), str(root / "HelperSources/PairingCore.swift"),
            str(root / "Sources/WorkSessionLinks.swift"), "-framework", "Security", "-framework", "AppKit",
            "-o", out + "/cos-control-helper"], cwd=root, capture_output=True, text=True)
        if build.returncode != 0:
            return build
        return subprocess.run(["/usr/bin/python3", str(root / "Tests/mac-recording-helper-checks.py"), out + "/cos-control-helper"], cwd=root, capture_output=True, text=True)
    return subprocess.run(["zsh", str(root / "Tests/run-mac-recording.sh")], cwd=root, env=dict(os.environ, COS_MAC_REC_LANE=lane), capture_output=True, text=True)

def named(out):
    for line in out.splitlines():
        if "Precondition failed" in line or "FAILED: [" in line or "AssertionError" in line:
            return line.strip()[:200]
    return None

args = [a for a in sys.argv[1:] if not a.startswith("--")]
if "--list" in sys.argv:
    for m in MUTANTS: print(m[0])
    sys.exit(0)
chosen = [m for m in MUTANTS if not args or any(m[0].startswith(a) for a in args)]
lanes = sorted({m[1] for m in chosen})
for lane in lanes:
    base = run(lane, ROOT)
    if base.returncode != 0:
        print(f"BASELINE RED ({lane}):\n{base.stdout[-2000:]}{base.stderr[-2000:]}"); sys.exit(2)
print("baseline green: " + ", ".join(lanes))
killed = survivors = infra = 0
for name, lane, rel, old, new in chosen:
    path = ROOT / rel
    src = path.read_text()
    if src.count(old) != 1 or old == new:
        print(f"{name}: NOT APPLIED (target found {src.count(old)} times)"); infra += 1; continue
    path.write_text(src.replace(old, new))
    try:
        if path.read_text() == src:
            print(f"{name}: NOT APPLIED (file unchanged)"); infra += 1; continue
        r = run(lane, ROOT)
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
print(f"mac recording robust mutants: {killed} killed, {survivors} survived, {infra} infrastructure, of {len(chosen)}")
sys.exit(1 if survivors or infra else 0)
