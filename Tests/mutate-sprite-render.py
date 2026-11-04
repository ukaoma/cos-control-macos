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
    # 0.5.368: the fixture is written with indent 2, so the list spans lines (the one-line target had stopped landing).
    ("smear exception dropped from the fixture", F, '"strip": "DefaultPet/duel",\n      "frames": [\n        29,\n        30,\n        31\n      ],',
     '"strip": "DefaultPet/duel",\n      "frames": [],'),
    ("pre-existing ceilings ignored", C, "        let holesCap = known?.holesCeiling ?? maxHolesPercent",
     "        let holesCap = maxHolesPercent"),
    # 0.5.368: the pinned per-frame evidence for Windu V13.2's plasma frames (working, frames 96-121).
    ("per-frame evidence hash ignored", C, "                  let data = try? Data(contentsOf: root.appendingPathComponent(pin.file)), sha256(data) == pin.sha256,",
     "                  let data = try? Data(contentsOf: root.appendingPathComponent(pin.file)),"),
    ("per-frame evidence need not match the strip", C, "                  let image = NSImage(data: data), let cg = PetSpriteStrip.raster(image), plane(cg).alpha == cell.alpha,",
     "                  let image = NSImage(data: data), let cg = PetSpriteStrip.raster(image),"),
    ("a holed hero is accepted", C, "              heroMeasure.gatedHolesPercent <= maxHolesPercent, heroMeasure.slivers.isEmpty,",
     "              heroMeasure.slivers.isEmpty,"),
    ("a hero at an unlisted edge is accepted", C, "              heroMeasure.edgeFrames.allSatisfy({ listed.contains(covered[$0 - 1]) })\n",
     "              true\n"),
    ("covered frames need not be consecutive", C, "first >= 1, last <= frames, covered == Array(first...last),", "first >= 1, last <= frames,"),
    ("the character may lose opacity under evidence", C, "                    guard Int(full.alpha[i]) + 2 >= Int(source.alpha[i]) else { return nil }\n", ""),
    ("the evidence entry dropped from the fixture", F, '"strip": "jedi-miles-windu/working",\n      "sourceFile": "windu-v13b-hero-frames96-121-1x.png"',
     '"strip": "jedi-miles-windu/working-unused",\n      "sourceFile": "windu-v13b-hero-frames96-121-1x.png"'),
    ("the strip's evidence hash changed in the fixture", F, '"sourceSHA256": "6afd3f89176526a0249b5f0f270e647ad6c05a7fdf7ebf46b59fd161f432dd0e"',
     '"sourceSHA256": "22ee0471aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'),
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
