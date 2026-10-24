#!/usr/bin/env python3
"""0.5.343 Build-up, in place: the mutation gate for the LIVE view (Sources/COSMotion.swift's COSBuildUp and its stage)
against Tests/BuildUpViewChecks.swift, which hosts the real view off screen and watches every frame it draws.

SERIAL and slow by design: each run is one full app compile (the view needs every Source), through Tests/compile-guard.sh
inside Tests/run-build-up.sh, on a scratch copy of the checkout. A GREEN baseline first, then each mutant must fail the
view lane with the behaviour it names ("check failed [<behaviour>]").

Usage: python3 Tests/mutate-build-up-view.py <repo root>
"""
import pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
MOTION = "Sources/COSMotion.swift"

# (name, old, new, the behaviour whose check must fail first)
MUTANTS = [
    ("the landing snaps the wire drawn", "let drawT = machine.drawT(at: t) ?? 0\n",
     "let drawT = machine.phase == .landing ? 9 : (machine.drawT(at: t) ?? 0)\n", "landing continuous"),
    ("the clock never pauses", "TimelineView(COSBuildUpSchedule(paused: !machine.needsFrames(windowActive: active)))",
     "TimelineView(COSBuildUpSchedule(paused: false))", "frames stop"),
    ("a seen view builds again", "quiet: frozen == nil && !COSBuildUpSession.memory.builds(memoryKey)", "quiet: false", "reopen quiet"),
]
FAILED = re.compile(r"check failed \[([^\]]+)\]")


def run(work: pathlib.Path) -> tuple[str, str]:
    lane = subprocess.run(["/bin/zsh", str(work / "Tests/run-build-up.sh")], env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(pathlib.Path.home()),
                          "COS_BUILD_UP_LANE": "view"}, capture_output=True, text=True)
    out = lane.stdout + lane.stderr
    if lane.returncode == 0:
        return "SURVIVED", ""
    found = FAILED.search(out)
    if found:
        return "FAILED", found.group(1)
    tail = [l for l in out.splitlines() if "error:" in l][:1] or out.strip().splitlines()[-1:]
    return "INVALID", tail[0] if tail else "no output"


work = pathlib.Path(tempfile.mkdtemp(prefix="cos-build-up-view-mutants-", dir="/private/tmp"))
try:
    for name in ("Sources", "Tests", "Resources"):
        shutil.copytree(root / name, work / name)
    original = (work / MOTION).read_text()
    for name, old, _, _ in MUTANTS:
        if original.count(old) != 1:
            sys.exit(f"mutant '{name}' targets {original.count(old)} sites; it must land exactly once")
    verdict, detail = run(work)
    if verdict != "SURVIVED":
        sys.exit(f"baseline is not green ({verdict}: {detail})")
    print("baseline green", flush=True)
    bad = []
    for name, old, new, expected in MUTANTS:
        (work / MOTION).write_text(original.replace(old, new))
        verdict, detail = run(work)
        ok = verdict == "FAILED" and detail == expected
        print(f"{'KILLED' if ok else verdict:13} {name}  <- {detail or 'every view check passed'}", flush=True)
        if not ok:
            bad.append(name)
        (work / MOTION).write_text(original)
    if bad:
        sys.exit(f"view mutation gate FAILED: {bad}")
    print(f"PASS build up view mutation gate: {len(MUTANTS)} mutants, each killed by its named check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
