#!/usr/bin/env python3
"""0.5.362: mutation gate for the cues in Copy full context (MeetingAskText.fullContext and cuesSection, executed by
Tests/MeetingAskChecks.swift and Tests/CueVerdictsChecks.swift through Tests/run-meeting-ask.sh).

Runs the unmutated lane first and refuses on a failure (a red baseline would "kill" every mutant). Then each mutant must
match its target EXACTLY ONCE, and is killed only when the lane fails with a named check ("Precondition failed" or
"... FAILED: ..."); a compile failure or any other exit is an infrastructure error, not a kill. The compile goes through
the lane, so through Tests/compile-guard.sh, one at a time. Usage: python3 Tests/mutate-cue-context.py
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANE = ROOT / "Tests" / "run-meeting-ask.sh"
CORE = "Sources/MeetingAskCore.swift"

MUTANTS = [
    ("X1 the cues are not in the copied context", CORE,
     "        if let cuesText = cuesSection(cues, note: cueNote, timeZone: timeZone) { sections.append(cuesText) }\n", ""),
    ("X2 the cues come right after the title", CORE,
     "        if let cuesText = cuesSection(cues, note: cueNote, timeZone: timeZone) { sections.append(cuesText) }\n",
     "        if let cuesText = cuesSection(cues, note: cueNote, timeZone: timeZone) { sections.insert(cuesText, at: 1) }\n"),
    ("X3 the coverage note is ignored", CORE, "cuesSection(cues, note: cueNote, timeZone: timeZone)", "cuesSection(cues, note: nil, timeZone: timeZone)"),
    ("X4 an empty section is always there", CORE, "        guard !rows.isEmpty || note != nil else { return nil }\n", "        guard true else { return nil }\n"),
    ("X5 the cues are not numbered from one", CORE, '            var lines = ["### C\\(index + 1) ', '            var lines = ["### C\\(index) '),
]


def run():
    return subprocess.run(["zsh", str(LANE)], cwd=ROOT, capture_output=True, text=True)


base = run()
if base.returncode != 0:
    print(f"BASELINE RED:\n{base.stdout[-3000:]}{base.stderr[-3000:]}")
    sys.exit(2)
print("baseline green")

survivors = infra = 0
for name, rel, old, new in MUTANTS:
    path = ROOT / rel
    src = path.read_text()
    count = src.count(old)
    if count != 1:
        print(f"{name}: NOT APPLIED (target found {count} times)")
        infra += 1
        continue
    path.write_text(src.replace(old, new))
    try:
        r = run()
        out = r.stdout + r.stderr
        failed_line = next((l for l in out.splitlines() if "FAILED:" in l or "Precondition failed" in l), None)
        if r.returncode != 0 and failed_line:
            print(f"{name}: killed by {failed_line.strip()[:220]}")
        elif r.returncode != 0:
            print(f"{name}: INFRASTRUCTURE (exit {r.returncode}, no named check)\n{out[-600:]}")
            infra += 1
        else:
            print(f"{name}: SURVIVED")
            survivors += 1
    finally:
        path.write_text(src)
print(f"cue context mutants: {len(MUTANTS) - survivors - infra} killed, {survivors} survived, {infra} infrastructure")
sys.exit(1 if survivors or infra else 0)
