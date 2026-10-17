#!/usr/bin/env python3
"""0.5.316 mutation gate for the Miles stock-pack refresh (PetSpriteStore.refreshRecognizedBundledDefault), executed by
Tests/ModelsContract.swift: stock promoted to the whole V12.6 pack, a customised pack untouched, an install that already
is V12.6 a no-op.

SERIAL by design, each compile through Tests/compile-guard.sh (Models.swift + ModelsContract.swift, never parallel; see
the 2026-10-07 kernel panics). Works on a scratch copy of Sources, Tests and Resources (ModelsContract finds the art
through #filePath), so the checkout is never mutated. A GREEN baseline is required before the first mutant. Each mutant
must replace its target exactly once and must make ModelsContract FAIL.

Usage: python3 Tests/mutate-pet-refresh.py <repo root>
"""
import os
import pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
MODELS = "Sources/Models.swift"
MUTANTS = [
    ("an install that already is V12.6 is rewritten (no .current)",
     "           }) {\n            return .current\n", "           }) {\n            return .notApplicable\n"),
    ("current ignores the bytes (an edited V12.6 strip counts as current)",
     "               return installedData == bundledData\n           }) {\n            return .current",
     "               return true\n           }) {\n            return .current"),
    ("current ignores the declared frame counts",
     "guard let mine = installed[pose], mine.file == row.file, mine.frames == row.frames,",
     "guard let mine = installed[pose], mine.file == row.file,"),
    ("the refresh promotes only the four stories again",
     "for pose in PetSpritePose.allCases where retainedStock[pose] != nil {",
     "for pose in [PetSpritePose.working, .duel, .trio, .swarm] {"),
    ("the stock 1.45x idle is treated as custom", "                || abs((installedScales[.idle] ?? 0) - 1.45) < 0.001\n", ""),
    ("a customised stock pack is promoted (byte check gone)",
     "            return installedData == bundledData\n        }) else { return .notApplicable }",
     "            return true\n        }) else { return .notApplicable }"),
    ("a replaced pose keeps the old interval",
     "                    intervalOverrides[story.pose] = interval\n", ""),
]


def compile_and_run(work: pathlib.Path) -> int:
    out = work / "models-contract"
    if out.exists():
        out.unlink()
    build = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), "/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0",
                            "-swift-version", "6", "-strict-concurrency=complete",
                            str(work / MODELS), str(work / "Tests/ModelsContract.swift"), "-framework", "AppKit", "-o", str(out)],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-2000:], file=sys.stderr)
        return 2
    return subprocess.run([str(out)], capture_output=True, text=True, cwd=work).returncode


work = pathlib.Path(tempfile.mkdtemp(prefix="cos-pet-refresh-mutants-", dir="/private/tmp"))
# Lanes compile against shared builds of Sources (Tests/kit-compile.py): keep them for every mutant of this run.
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
try:
    for folder in ("Sources", "Tests", "Resources"):
        shutil.copytree(root / folder, work / folder)
    original = (work / MODELS).read_text()
    if compile_and_run(work) != 0:
        sys.exit("baseline is not green: fix ModelsContract before reading any mutant")
    print("baseline GREEN")
    survivors = []
    for name, old, new in MUTANTS:
        if original.count(old) != 1:
            sys.exit(f"mutant '{name}' targets {original.count(old)} sites; it must land exactly once")
        (work / MODELS).write_text(original.replace(old, new))
        code = compile_and_run(work)
        verdict = "KILLED (did not compile)" if code == 2 else ("KILLED" if code != 0 else "SURVIVED")
        print(f"{verdict:24} {name}", flush=True)
        if code == 0:
            survivors.append(name)
        (work / MODELS).write_text(original)
    if survivors:
        sys.exit(f"{len(survivors)} survivor(s): {survivors}")
    print(f"PASS pet refresh mutation gate: {len(MUTANTS)} mutants, all killed, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
