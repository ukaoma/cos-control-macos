#!/usr/bin/env python3
"""0.5.360 (0.5.368: re-anchored on generation 29, Windu Motion V13) mutation gate for Tests/pet-art-generation-pins.py: a bundled pack's state map and petDefaultArtGeneration
move together. 0.5.360 first shipped Windu Motion V2 with the generation left at 27 (installs already at 27 skip the
upgrade block), and the only pin then ("generation >= 26") passed.

No compile, a scratch copy of only the files the pin reads. GREEN baseline first. Each mutant must replace its target
exactly once and the pin must fail with the message that NAMES the behaviour (a crash or a different message is not a
kill). The tag mutant needs the real repository's tags, so COS_PIN_GIT_ROOT points the scratch copy at it.

Usage: python3 Tests/mutate-pet-art-generation.py <repo root>
"""
import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
PIN = "Tests/pet-art-generation-pins.py"
CONTROLLER = "Sources/ControllerModel.swift"
WINDU = "Resources/BundledCharacters/jedi-miles-windu/session-pet-states.json"
NIA = "Resources/BundledCharacters/jedi-nia-solari/session-pet-states.json"
DEFAULT = "Resources/DefaultPet/session-pet-states.json"
HISTORY = "Resources/BundledCharacters/jedi-miles-windu/stock-state-history.json"
FILES = [PIN, CONTROLLER, WINDU, NIA, DEFAULT, HISTORY,
         "Resources/BundledCharacters/jedi-elara-vale/session-pet-states.json",
         "Resources/BundledCharacters/jedi-rowan-vale/session-pet-states.json"]
V13_HASH = "be30092cdffca5347f4ed1cc4cf01909778a64aeaf09583e673ef629047cc320"
V2_HASH = "0292c01a15077ee7c28d61fb7d82b86b6959c2137fd55a30dc9375f18c7a2313"
V1_HASH = "2ba8634a87ccbc0ec37bb10a383e4ffd76aba30122a31df120516f70513c39d1"
ENTRY_28 = f'        (28, "{V2_HASH}"),  # Windu Motion V2, 0.5.360\n'
ENTRY_29 = f'        (29, "{V13_HASH}"),  # Windu Motion V13 working, Session 3 V4 trio, 0.5.368\n'
POSES = '"poses": {'
STATE_EDIT = (POSES, POSES + '\n    "zz-mutant": {"file": "x.png", "frames": 1},')

# (name, [(file, old, new)], text the pin's failure must contain)
# 0.5.368: generation 29 (Windu Motion V13) is the newest entry, so the "latest" mutants anchor on it; 28 is now a replaced map.
MUTANTS = [
    ("the Windu state map changes and the generation does not",
     [(WINDU, *STATE_EDIT)], "jedi-miles-windu: session-pet-states.json changed"),
    ("another Jedi state map changes and the generation does not",
     [(NIA, *STATE_EDIT)], "jedi-nia-solari: session-pet-states.json changed"),
    ("the retained Miles default changes and the generation does not",
     [(DEFAULT, *STATE_EDIT)], "DefaultPet: session-pet-states.json changed"),
    ("the Windu state map goes back to Motion V2 at generation 29",
     [(PIN, ENTRY_29, f'        (29, "{V2_HASH}"),\n')], "jedi-miles-windu: session-pet-states.json changed"),
    ("the Motion V13 map ships with no generation 29 entry",
     [(PIN, ENTRY_29, "")], "jedi-miles-windu: session-pet-states.json changed"),
    ("the constant goes back to 28 under the Motion V13 map",
     [(CONTROLLER, "petDefaultArtGeneration = 29", "petDefaultArtGeneration = 28")],
     "the ledger reaches generation 29 but petDefaultArtGeneration is 28"),
    ("a map change gets its ledger entry at 30 and the constant stays 29",
     [(WINDU, *STATE_EDIT),
      (PIN, ENTRY_29, ENTRY_29 + '        (30, "{SHA:' + WINDU + '}"),\n')],
     "the ledger reaches generation 30 but petDefaultArtGeneration is 29"),
    ("two ledger entries claim the same generation",
     [(PIN, ENTRY_29, ENTRY_29 + ENTRY_29)], "ledger generations must strictly increase"),
]
MUTANTS += [
    ("the Motion V1 map leaves the Windu history",
     [(HISTORY, '"name": "Windu Motion V1 \u00b7 Control 0.5.350",\n      "retainedSource": "bundled-character",\n      "state": {\n        "poses": {',
       '"name": "Windu Motion V1 \u00b7 Control 0.5.350",\n      "retainedSource": "bundled-character",\n      "state": {\n        "poses": {\n          "zz-mutant": {"file": "x.png", "frames": 1},')],
     "generation 27 is not in stock-state-history.json"),
    ("the Motion V2 map leaves the Windu history",
     [(HISTORY, '"name": "Windu Motion V2 \u00b7 Control 0.5.360",\n      "retainedSource": "bundled-character",\n      "state": {\n        "poses": {',
       '"name": "Windu Motion V2 \u00b7 Control 0.5.360",\n      "retainedSource": "bundled-character",\n      "state": {\n        "poses": {\n          "zz-mutant": {"file": "x.png", "frames": 1},')],
     "generation 28 is not in stock-state-history.json"),
    ("a pack folder is not in the ledger",
     [("NEWPACK", "", "{}")], "is not in the ledger"),
    ("a replaced map has no recorded hash",
     [(PIN, '    ("BundledCharacters/jedi-miles-windu", 27): "07db3f086b1595b779694c20f70e2e1de63822de71ec131eaa22758a0a51f7bf",\n', "")],
     "was replaced by a later map"),
    ("the replaced Motion V2 map has no recorded hash",
     [(PIN, '    ("BundledCharacters/jedi-miles-windu", 28): "b652308e6cc05a078d5e8709ffd2eed3e1880ec03e2feb731a7204ab7802fdef",\n', "")],
     "generation 28 was replaced by a later map"),
]
# The one the local checks cannot see: the shipped 0.5.361/0.5.363 entry (generation 28) is rewritten to match a changed map
# and the number stays at 28. Disk, ledger and constant agree with each other; only the released tags disagree.
TAG_MUTANT = ("a released entry is rewritten to match a changed map and the generation stays 28",
              [(PIN, ENTRY_29, ""),
               (PIN, ENTRY_28, f'        (28, "{V13_HASH}"),\n'),
               (CONTROLLER, "petDefaultArtGeneration = 29", "petDefaultArtGeneration = 28")],
              "shipped BundledCharacters/jedi-miles-windu at generation 28")

def run_pin(work: pathlib.Path):
    env = dict(os.environ, COS_PIN_GIT_ROOT=str(root))
    done = subprocess.run([sys.executable, str(work / PIN), str(work)], capture_output=True, text=True, env=env)
    return done.returncode, (done.stderr + done.stdout).strip()


def apply(work: pathlib.Path, edits) -> None:
    """Each edit lands exactly once. {SHA:<path>} in new text is that file's sha256 as edited so far. NEWPACK adds a pack folder."""
    for relative, old, new in edits:
        if relative == "NEWPACK":
            (work / "Resources/BundledCharacters/jedi-extra").mkdir(exist_ok=True)
            continue
        text = (work / relative).read_text()
        if text.count(old) != 1:
            sys.exit(f"edit in {relative} targets {text.count(old)} sites; it must land exactly once")
        new = re.sub(r"\{SHA:([^}]+)\}", lambda m: hashlib.sha256((work / m.group(1)).read_bytes()).hexdigest(), new)
        (work / relative).write_text(text.replace(old, new))


work = pathlib.Path(tempfile.mkdtemp(prefix="cos-pet-art-generation-mutants-", dir="/private/tmp"))
try:
    for relative in FILES:
        (work / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, work / relative)
    originals = {relative: (work / relative).read_text() for relative in FILES}
    code, output = run_pin(work)
    if code != 0:
        sys.exit(f"baseline is not green: {output}")
    print(f"baseline GREEN: {output}")
    survivors = []
    for name, edits, wanted in MUTANTS + [TAG_MUTANT]:
        apply(work, edits)
        code, output = run_pin(work)
        verdict = "SURVIVED" if code == 0 else ("KILLED" if wanted in output else "CRASHED")
        print(f"{verdict:10} {name}" + (f"  <- {output.splitlines()[-1][:110]}" if code != 0 else ""), flush=True)
        if verdict != "KILLED":
            survivors.append(name)
        for relative, text in originals.items():
            (work / relative).write_text(text)
        extra = work / "Resources/BundledCharacters/jedi-extra"
        if extra.exists():
            extra.rmdir()
    if survivors:
        sys.exit(f"{len(survivors)} mutant(s) not killed by the check that names them: {survivors}")
    print(f"PASS pet art generation mutation gate: {len(MUTANTS) + 1} mutants, each killed by the named check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
