#!/usr/bin/env python3
"""0.5.368 mutation gate for the Windu Motion V13 guards in Tests/illustrated-pack-pins.py. No compile.

The pack is ~600 MB, so the scratch copy hard-links every PNG and copies the JSON; a mutant that changes a PNG unlinks the
link first and writes new bytes, so the repository's file is never touched. GREEN baseline first. Each mutant must land
exactly once and the pin must fail with the assertion that NAMES the behaviour (a different failure is not a kill).

Usage: python3 Tests/mutate-windu-v13-pins.py <repo root>
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
PACK = "Resources/BundledCharacters/jedi-miles-windu"
COPY = ["Tests/illustrated-pack-pins.py", "Tests/illustrated-pack-sha256.json", "Tests/ambient-pack-sha256.json",
        "Tests/windu-motion-sha256.json", "Tests/windu-motion-v13-sha256.json", "Resources/DefaultPet/session-pet-states.json"]
MAP = f"{PACK}/session-pet-states.json"
HISTORY = f"{PACK}/stock-state-history.json"
MANIFEST = "Tests/windu-motion-v13-sha256.json"


def text_edit(relative, old, new):
    def run(work):
        path = work / relative
        text = path.read_text()
        if text.count(old) != 1:
            sys.exit(f"edit in {relative} targets {text.count(old)} sites; it must land exactly once")
        path.write_text(text.replace(old, new))
    return run


def json_edit(relative, change):
    def run(work):
        path = work / relative
        data = json.loads(path.read_text())
        before = json.dumps(data, sort_keys=True)
        change(data)
        if json.dumps(data, sort_keys=True) == before:
            sys.exit(f"mutant on {relative} did not change it")
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    return run


def png_edit(name):
    def run(work):
        path = work / PACK / name
        data = path.read_bytes()
        path.unlink()
        path.write_bytes(data + b"\0")
    return run


def png_remove(name):
    def run(work):
        (work / PACK / name).unlink()
    return run


def set_trio_handoff(data):
    data["poses"]["trio"]["rotation"]["handoffFrame"] = 120


def entry_swap(data):
    variant = data["poses"]["working"]["rotation"]["variants"][1]
    variant["entryFile"] = "windu-illustrated-v1-working-a-entry-1x.png"


def drop_v2(data):
    data["maps"] = [m for m in data["maps"] if m["name"] != "Windu Motion V2 · Control 0.5.360"]


def manifest_drop(data):
    data.pop("windu-motion-v13-working-d-body-1x.png")


MUTANTS = [
    ("a V13 strip changes by one byte", png_edit("windu-motion-v13-working-b-full-2x-s3.png"), "windu-motion-v13-working-b-full-2x-s3.png"),
    ("a retained Session 3 dependency changes", png_edit("windu-illustrated-v1-trio-c-full-2x-s4.png"), "windu-illustrated-v1-trio-c-full-2x-s4.png"),
    # Killed first by the spec line (trio 172 frames, 3 casts, handoff 121), before the map hash: the gate that names it.
    ("the trio handoff moves", json_edit(MAP, set_trio_handoff), "r['handoffFrame']==handoff"),
    ("the map is re-pinned but a cast's entry is swapped",
     lambda work: (json_edit(MAP, entry_swap)(work),
                   text_edit("Tests/illustrated-pack-pins.py", "838f747305f3690cc3a6b787a3e75188677795bc27d7c9308fb5bad72369bba3",
                             __import__("hashlib").sha256((work / MAP).read_bytes()).hexdigest())(work)),
     "working row"),
    ("the Motion V2 map leaves the stock history", json_edit(HISTORY, drop_v2), "assert len(v2)==1"),
    # Killed by the 36 retained motion pins (Tests/windu-motion-sha256.json) before the V2 history file check is reached.
    ("a Motion V2 rollback file is deleted", png_remove("windu-motion-v2-working-c-body-1x.png"), "windu-motion-v2-working-c-body-1x.png"),
    ("the V13 manifest loses a file", json_edit(MANIFEST, manifest_drop), "assert len(v13)==105"),
]


def run_pin(work):
    done = subprocess.run([sys.executable, str(work / "Tests/illustrated-pack-pins.py"), str(work)], capture_output=True, text=True)
    return done.returncode, (done.stderr + done.stdout).strip()


def build(work):
    for relative in COPY:
        (work / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, work / relative)
    (work / PACK).mkdir(parents=True, exist_ok=True)
    for item in (root / PACK).iterdir():
        if item.suffix == ".png":
            os.link(item, work / PACK / item.name)
        else:
            shutil.copy2(item, work / PACK / item.name)


base = pathlib.Path(tempfile.mkdtemp(prefix="cos-windu-v13-mutants-", dir="/private/tmp"))
try:
    work = base / "baseline"
    build(work)
    code, output = run_pin(work)
    if code != 0:
        sys.exit(f"baseline is not green: {output}")
    print(f"baseline GREEN: {output.splitlines()[-1]}")
    shutil.rmtree(work)
    survivors = []
    for index, (name, mutate, wanted) in enumerate(MUTANTS):
        work = base / f"m{index}"
        build(work)
        mutate(work)
        code, output = run_pin(work)
        verdict = "SURVIVED" if code == 0 else ("KILLED" if wanted in output else "CRASHED")
        print(f"{verdict:10} {name}" + (f"  <- {output.splitlines()[-1][:110]}" if code != 0 else ""), flush=True)
        if verdict != "KILLED":
            survivors.append(name)
            print(output[-800:])
        shutil.rmtree(work)
    untouched = all(not (root / PACK / f).read_bytes().endswith(b"\0") for f in
                    ["windu-motion-v13-working-b-full-2x-s3.png", "windu-illustrated-v1-trio-c-full-2x-s4.png"])
    print("repository pack untouched:", untouched and (root / PACK / "windu-motion-v2-working-c-body-1x.png").is_file())
    if survivors or not untouched:
        sys.exit(f"{len(survivors)} mutant(s) not killed by the check that names them: {survivors}")
    print(f"PASS Windu V13 pin mutation gate: {len(MUTANTS)} mutants, each killed by the named check, green baseline")
finally:
    shutil.rmtree(base, ignore_errors=True)
