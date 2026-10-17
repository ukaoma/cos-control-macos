#!/usr/bin/env python3
"""0.5.316 mutation gate for Tests/SpriteRenderContract.swift: each rule (fade, eaten patch, ownership, bulk, edge
allowlist, speck floor, smear exception, pre-existing ceilings) must be load-bearing. SERIAL, each compile through
Tests/compile-guard.sh (Models.swift + SpriteRenderContract.swift), on a scratch copy; green baseline required first.

Usage: python3 Tests/mutate-sprite-render.py <repo root>
"""
import os
import pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1]).resolve()
C = "Tests/SpriteRenderContract.swift"; F = "Tests/fixtures/sprite-render/approved-exceptions.json"
MUTANTS = [
    ("fade never applies (fadeShare 1.01)", C, "    static let fadeShare = 0.8\n", "    static let fadeShare = 1.01\n"),
    ("every translucent patch is a fade (fadeShare 0.1)", C, "    static let fadeShare = 0.8\n", "    static let fadeShare = 0.1\n"),
    ("no minimum size for a fade (fadeMinHoles 0)", C, "    static let fadeMinHoles = 100\n", "    static let fadeMinHoles = 0\n"),
    ("ownership always true", C, "                if !continues && members.count <= other { slivers.append(name) }",
     "                if false && !continues && members.count <= other { slivers.append(name) }"),
    ("bulk rule removed", C, "                if !continues && members.count <= other { slivers.append(name) }",
     "                if !continues { slivers.append(name) }"),
    ("edge allowlist ignored", C, "        let allowed = Set(fixture.edgeFrames[label] ?? []).union(known?.edgeFrames ?? [])",
     "        let allowed = Set(known?.edgeFrames ?? [])"),
    ("speck floor removed", C, "    static let speckMaxPixels = 15\n", "    static let speckMaxPixels = 0\n"),
    ("smear exception dropped from the fixture", F, '"frames": [29, 30, 31]', '"frames": []'),
    ("pre-existing ceilings ignored", C, "        let holesCap = known?.holesCeiling ?? maxHolesPercent",
     "        let holesCap = maxHolesPercent"),
]
work = pathlib.Path(tempfile.mkdtemp(prefix="cos-sprite-mutants-", dir="/private/tmp"))
# Lanes compile against shared builds of Sources (Tests/kit-compile.py): keep them for every mutant of this run.
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
def run():
    out = work / "sprite-render"
    if out.exists(): out.unlink()
    b = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), "/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6",
                        "-strict-concurrency=complete", str(work / "Sources/Models.swift"), str(work / C), "-framework", "AppKit", "-o", str(out)],
                       capture_output=True, text=True)
    if b.returncode != 0: return 2, b.stderr[-400:]
    r = subprocess.run([str(out)], capture_output=True, text=True, cwd=work)
    last = [l for l in r.stdout.splitlines() if "self-check:" in l or l.startswith("  - ")][:2]
    return r.returncode, " | ".join(last)[:220]
try:
    (work / "Sources").mkdir(); (work / "Tests/fixtures").mkdir(parents=True)
    shutil.copy(root / "Sources/Models.swift", work / "Sources/Models.swift")
    shutil.copy(root / C, work / C)
    shutil.copytree(root / "Tests/fixtures/sprite-render", work / "Tests/fixtures/sprite-render")
    shutil.copytree(root / "Resources", work / "Resources")
    code, msg = run()
    if code != 0: sys.exit(f"baseline not green: {code} {msg}")
    print("baseline GREEN", flush=True)
    survivors = []
    for name, path, old, new in MUTANTS:
        text = (work / path).read_text()
        if text.count(old) != 1: sys.exit(f"{name}: target count {text.count(old)}")
        (work / path).write_text(text.replace(old, new))
        code, msg = run()
        print(f"{'KILLED' if code == 1 else ('NO-COMPILE' if code == 2 else 'SURVIVED'):9} {name} :: {msg}", flush=True)
        if code != 1: survivors.append(name)
        (work / path).write_text(text)
    if survivors: sys.exit(f"{len(survivors)} mutant(s) not killed by a failing contract: {survivors}")
    print(f"PASS sprite render mutation gate: {len(MUTANTS)} mutants, all killed, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
