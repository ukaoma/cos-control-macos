#!/usr/bin/env python3
"""0.5.343 Build-up, in place: the mutation gate for the LIVE view (COSBuildUp and its stage in Sources/COSMotion.swift, and what it reads from Models.swift)
against Tests/BuildUpViewChecks.swift, which hosts the real view off screen and watches every frame it draws.

SERIAL and slow by design: each run is one full app compile (the view needs every Source), through Tests/compile-guard.sh
inside Tests/run-build-up.sh, on a scratch copy of the checkout. A GREEN baseline first, then each mutant must fail the
view lane with the behaviour it names ("check failed [<behaviour>]").

Usage: python3 Tests/mutate-build-up-view.py <repo root> [--only <name prefix>]
"""
import pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
MOTION = "Sources/COSMotion.swift"
MODELS = "Sources/Models.swift"

# (name, old, new, the behaviour whose check must fail first)
MUTANTS = [
    ("the landing snaps the wire drawn", MOTION, "drawT: machine.drawT(at: t) ?? 0, landT: machine.landT(at: t),",
     "drawT: machine.phase == .landing ? 9 : (machine.drawT(at: t) ?? 0), landT: machine.landT(at: t),", "landing continuous"),
    ("the clock never pauses", MOTION, "TimelineView(COSBuildUpSchedule(paused: !machine.needsFrames(windowActive: active)))",
     "TimelineView(COSBuildUpSchedule(paused: false))", "frames stop"),
    ("an opaque tint", MOTION, "            .compositingGroup()\n            .opacity(curtain)\n", "            .compositingGroup()\n            .opacity(curtain > 0 ? 1 : 0)\n",
     "curtain light"),
    ("a stacked fill (0.5.343 at 32debce)", MOTION, "            ZStack(alignment: .topLeading) {\n                Rectangle().fill(background)\n                if item.style == .card {\n                    RoundedRectangle(cornerRadius: item.radius, style: .continuous)\n                        .fill(COSPalette.card)\n                        .frame(width: box.width, height: box.height)\n                        .mask(alignment: .leading) { Rectangle().frame(width: box.width * look.fill) }\n                        .offset(x: box.minX, y: box.minY - top)\n                }\n            }\n            .compositingGroup()\n            .opacity(curtain)\n",
     "            ZStack(alignment: .topLeading) {\n                Rectangle().fill(background).opacity(curtain)\n                if item.style == .card {\n                    RoundedRectangle(cornerRadius: item.radius, style: .continuous)\n                        .fill(COSPalette.card)\n                        .opacity(curtain)\n                        .frame(width: box.width, height: box.height)\n                        .mask(alignment: .leading) { Rectangle().frame(width: box.width * look.fill) }\n                        .offset(x: box.minX, y: box.minY - top)\n                }\n            }\n", "curtain light"),
    ("data never clears the empty mark", MOTION, "        guard frozen == nil, landed, key == nil, COSBuildUpSession.memory.empty.contains(memoryKey) else { return }",
     "        guard frozen == nil, landed, key == nil, COSBuildUpSession.memory.empty.contains(memoryKey), false else { return }", "empty cleared"),
    ("the stage ignores the view's height", MOTION, "COSBuildUpPlan.items(shape, tune, limit: limit, fitting: height,",
     "COSBuildUpPlan.items(shape, tune, limit: limit, fitting: nil,", "fit"),
    ("the answer never re-fits", MOTION, "measured: shape == .answer && phase == .landing ? height : nil)", "measured: nil)", "answer refit"),
    ("the hand-off hides the content", MODELS, "        phase == .grace || (phase == .building && !wordsShown)",
     "        phase == .grace || phase == .handoff || (phase == .building && !wordsShown)", "never hides data"),
    ("a seen view builds again", MOTION, "quiet: !enabled || !COSBuildUpSession.memory.builds(memoryKey)", "quiet: !enabled || false", "empty remembered"),
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
    originals = {path: (work / path).read_text() for path in (MOTION, MODELS)}
    for name, path, old, _, _ in MUTANTS:
        if originals[path].count(old) != 1:
            sys.exit(f"mutant '{name}' targets {originals[path].count(old)} sites; it must land exactly once")
    verdict, detail = run(work)
    if verdict != "SURVIVED":
        sys.exit(f"baseline is not green ({verdict}: {detail})")
    print("baseline green", flush=True)
    bad = []
    for name, path, old, new, expected in [m for m in MUTANTS if m[0].startswith(only)]:
        (work / path).write_text(originals[path].replace(old, new))
        verdict, detail = run(work)
        ok = verdict == "FAILED" and detail == expected
        print(f"{'KILLED' if ok else verdict:13} {name}  <- {detail or 'every view check passed'}", flush=True)
        if not ok:
            bad.append(name)
        (work / path).write_text(originals[path])
    if bad:
        sys.exit(f"view mutation gate FAILED: {bad}")
    selected = len([m for m in MUTANTS if m[0].startswith(only)])
    print(f"PASS build up view mutation gate: {selected} mutants" + (f" (of {len(MUTANTS)}, named {only!r})" if only else "")
          + ", each killed by its named check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
