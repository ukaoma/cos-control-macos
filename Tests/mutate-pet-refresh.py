#!/usr/bin/env python3
"""0.5.316 mutation gate for the Miles stock-pack refresh (PetSpriteStore.refreshRecognizedBundledDefault), executed by
Tests/ModelsContract.swift: stock promoted to the whole bundled pack, a customised pack untouched, an install that already
is the bundled pack a no-op. 0.5.325: the bundled pack is V14 timing-v2 with its casts; the exact stock V12.6 map is
promoted with every cast layer, any other V12.6 is the person's, and V14 under flat or subfolder names is current.

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
     "               return installedData == bundledData && sameRotation(pose)\n           }) {\n            return .current",
     "               return sameRotation(pose)\n           }) {\n            return .current"),
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
    # 0.5.325 (generation 22, V14 timing-v2 with three casts on duel, trio and swarm).
    ("current ignores the casts (V13 without casts reads as V14)",
     "               return installedData == bundledData && sameRotation(pose)\n",
     "               return installedData == bundledData\n"),
    ("a cast layer counts as current by name, not bytes",
     "                    return mineData == wantedData\n", "                    return true\n"),
    ("a tuned V12.6 is promoted (exact-map gate gone)",
     "                guard installedCanonical != nil, installedCanonical == canonical(state) else { return .notApplicable }\n", ""),
    ("the upgrade lands the strips without their casts",
     "            rotationRows[story.pose] = rotationJSON\n", ""),
    ("a cast layer the wrong size is accepted",
     "                          layer.width == strip.width, layer.height == strip.height\n",
     "                          layer.width > 0\n"),
    ("a missing cast layer is skipped instead of refusing the upgrade",
     "                        return .failed\n                    }\n                    layers[file] = data",
     "                        continue\n                    }\n                    layers[file] = data"),
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
    run = subprocess.run([str(out)], capture_output=True, text=True, cwd=work)
    # 0.5.325: name the check that caught it (a precondition message from ModelsContract), so a kill is attributed.
    found = [l for l in (run.stderr + run.stdout).splitlines() if "ModelsContract.swift" in l and "Precondition failed" in l]
    compile_and_run.caught = found[-1].split("Precondition failed: ", 1)[1].strip() if found else ""
    return run.returncode


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
        # 0.5.325: a mutant that does not compile proves nothing about the checks (INVALID, fails the gate), and a crash
        # outside a named check is not a kill either.
        caught = getattr(compile_and_run, "caught", "") if code not in (0, 2) else ""
        verdict = "INVALID (no compile)" if code == 2 else ("SURVIVED" if code == 0 else ("KILLED" if caught else "CRASHED"))
        print(f"{verdict:24} {name}" + (f"  <- {caught}" if caught else ""), flush=True)
        if verdict != "KILLED":
            survivors.append(name)
        (work / MODELS).write_text(original)
    if survivors:
        sys.exit(f"{len(survivors)} mutant(s) not killed by a named check: {survivors}")
    print(f"PASS pet refresh mutation gate: {len(MUTANTS)} mutants, each killed by a named ModelsContract check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
