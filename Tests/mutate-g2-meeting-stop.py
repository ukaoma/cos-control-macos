#!/usr/bin/env python3
"""0.5.321: mutation gate for Stop and save on a glasses meeting.

Runs the unmutated lanes first and refuses on any failure (a red baseline would "kill" every mutant). Then each
mutant must match its target EXACTLY ONCE, and is killed only when its lane fails with a named check
("... FAILED: ..."); a compile failure is an infrastructure error, not a kill. Compiles go through the lane, so through
Tests/compile-guard.sh, one at a time. Usage: python3 Tests/mutate-g2-meeting-stop.py
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANE = ROOT / "Tests" / "run-g2-meeting-stop.sh"

MUTANTS = [
    ("C1 the pane's button stops without the confirmation", "pins", "Sources/ActivityMeetings.swift",
     "Button(G2MeetingStop.buttonLabel) { confirmGlassesStop = true }",
     "Button(G2MeetingStop.buttonLabel) { if let id = model.liveTranscriptOpenID { model.stopGlassesMeeting(id) } }"),
    ("C2 the panel's button stops without the confirmation", "pins", "Sources/Views.swift",
     "Button(G2MeetingStop.buttonLabel) { glassesStopTarget = id }",
     "Button(G2MeetingStop.buttonLabel) { model.stopGlassesMeeting(id) }"),
    ("C3 the Live now row's button stops without the confirmation", "pins", "Sources/ActivityMeetings.swift",
     "Button(G2MeetingStop.buttonLabel) { glassesStopTarget = row.sessionId }",
     "Button(G2MeetingStop.buttonLabel) { model.stopGlassesMeeting(row.sessionId) }"),
    ("C4 the model takes any session", "pins", "Sources/ControllerModel.swift",
     "guard G2MeetingStop.isGlassesSession(sessionId), glassesMeetingStop?.phase.isActive != true else { return }",
     "guard glassesMeetingStop?.phase.isActive != true else { return }"),
    ("C5 the model saves from the Mac", "pins", "Sources/ControllerModel.swift",
     'let first = try? await helper.run(["meeting-stop-request", "--session", sessionId], timeout: 20)',
     'let first = try? await helper.run(["meeting-stranded-save", "--session", sessionId], timeout: 20)'),
    ("M1 401 loses its words", "models", "Sources/LiveTranscript.swift",
     "        case 401, 403: return Request(phase: .unauthorized, requestId: nil, claimWindowSeconds: 0)\n", ""),
    ("M2 an unreachable server reads as stopping", "models", "Sources/LiveTranscript.swift",
     "            return elapsed > deadline ? .serverUnreachable : .asking\n", "            return .stopping\n"),
    ("M3 no grace past the claim window", "models", "Sources/LiveTranscript.swift",
     "let deadline = claimWindowSeconds + claimGraceSeconds", "let deadline = claimWindowSeconds"),
    ("M4 not connected does not say nothing stopped", "models", "Sources/LiveTranscript.swift",
     '"Glasses not connected. Nothing was stopped. Stop it', '"Glasses not connected. Stop it'),
    ("M5 an expired request keeps asking", "models", "Sources/LiveTranscript.swift",
     'case "expired": return .notConnected', 'case "expired": return .asking'),
    ("M6 a Mac recording is asked about", "models", "Sources/LiveTranscript.swift",
     '!sessionId.hasPrefix("mac_") && sessionId.range(', 'sessionId.range('),
    ("M7 already stopped loses its words", "models", "Sources/LiveTranscript.swift",
     '        case 409 where body["reason"]?.string == "not_live": return Request(phase: .alreadyStopped, requestId: nil, claimWindowSeconds: 0)\n', ""),
    # 0.5.321, same release: the Meeting Ask export's wording (Tests/run-meeting-ask.sh).
    ("A1 the export prints the meeting position as milliseconds", "ask", "Sources/MeetingAskCore.swift",
     'var line = "Model: \\(exchange.model ?? exchange.selectedModel.label) · Through \\(through) · \\(exchange.status)"',
     'var line = "Model: \\(exchange.model ?? exchange.selectedModel.label) · through \\(exchange.throughMs) ms · \\(exchange.status)"'),
    ("A2 the export prints an answer time the server never sent", "ask", "Sources/MeetingAskCore.swift",
     'if let total = exchange.timings?.totalMs { line += " · Answer time: " + String(format: "%.1f s", total / 1000) }',
     'line += " · Answer time: " + String(format: "%.1f s", (exchange.timings?.totalMs ?? 0) / 1000)'),
    ("A3 the export drops the answer time", "ask", "Sources/MeetingAskCore.swift",
     'if let total = exchange.timings?.totalMs { line += " · Answer time: " + String(format: "%.1f s", total / 1000) }', ""),
]


def run(lane):
    if lane == "ask":
        return subprocess.run(["zsh", str(ROOT / "Tests" / "run-meeting-ask.sh")], cwd=ROOT, capture_output=True, text=True)
    env = dict(os.environ, COS_G2_STOP_LANE=lane)
    return subprocess.run(["zsh", str(LANE)], cwd=ROOT, env=env, capture_output=True, text=True)


for lane in ("pins", "models", "ask"):
    base = run(lane)
    if base.returncode != 0:
        print(f"BASELINE RED ({lane}):\n{base.stdout}{base.stderr}")
        sys.exit(2)
print("baseline green: pins, models, ask")

survivors = infra = 0
for name, lane, rel, old, new in MUTANTS:
    path = ROOT / rel
    src = path.read_text()
    count = src.count(old)
    if count != 1:
        print(f"{name}: NOT APPLIED (target found {count} times)")
        infra += 1
        continue
    path.write_text(src.replace(old, new))
    try:
        r = run(lane)
        out = r.stdout + r.stderr
        failed_line = next((l for l in out.splitlines() if "FAILED:" in l or "Precondition failed" in l), None)
        if r.returncode != 0 and failed_line:
            print(f"{name}: killed by {failed_line.strip()}")
        elif r.returncode != 0:
            print(f"{name}: INFRASTRUCTURE (exit {r.returncode}, no named check)\n{out[-600:]}")
            infra += 1
        else:
            print(f"{name}: SURVIVED")
            survivors += 1
    finally:
        path.write_text(src)
print(f"g2 meeting stop mutants: {len(MUTANTS) - survivors - infra} killed, {survivors} survived, {infra} infrastructure")
sys.exit(1 if survivors or infra else 0)
