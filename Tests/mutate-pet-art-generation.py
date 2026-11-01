#!/usr/bin/env python3
"""0.5.360 mutation gate for Tests/pet-art-generation-pins.py: a bundled pack's state map and petDefaultArtGeneration
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
V2_HASH = "0292c01a15077ee7c28d61fb7d82b86b6959c2137fd55a30dc9375f18c7a2313"
V1_HASH = "2ba8634a87ccbc0ec37bb10a383e4ffd76aba30122a31df120516f70513c39d1"
ENTRY_28 = f'        (28, "{V2_HASH}"),  # Windu Motion V2, 0.5.360\n'
POSES = '"poses": {'
STATE_EDIT = (POSES, POSES + '\n    "zz-mutant": {"file": "x.png", "frames": 1},')

# (name, [(file, old, new)], text the pin's failure must contain)
MUTANTS = [
    ("the Windu state map changes and the generation does not",
     [(WINDU, *STATE_EDIT)], "jedi-miles-windu: session-pet-states.json changed"),
    ("another Jedi state map changes and the generation does not",
     [(NIA, *STATE_EDIT)], "jedi-nia-solari: session-pet-states.json changed"),
    ("the retained Miles default changes and the generation does not",
     [(DEFAULT, *STATE_EDIT)], "DefaultPet: session-pet-states.json changed"),
    ("the Windu state map goes back to Motion V1 at generation 28",
     [(PIN, ENTRY_28, f'        (28, "{V1_HASH}"),\n')], "jedi-miles-windu: session-pet-states.json changed"),
    ("the constant goes back to 27 under the Motion V2 map",
     [(CONTROLLER, "petDefaultArtGeneration = 28", "petDefaultArtGeneration = 27")],
     "the ledger reaches generation 28 but petDefaultArtGeneration is 27"),
    ("a map change gets its ledger entry at 29 and the constant stays 28",
     [(WINDU, *STATE_EDIT),
      (PIN, ENTRY_28, ENTRY_28 + '        (29, "{SHA:' + WINDU + '}"),\n')],
     "the ledger reaches generation 29 but petDefaultArtGeneration is 28"),
    ("two ledger entries claim the same generation",
     [(PIN, ENTRY_28, ENTRY_28 + ENTRY_28)], "ledger generations must strictly increase"),
]
MUTANTS += [
    ("the Motion V1 map leaves the Windu history",
     [(HISTORY, '"windu-motion-v1-working-b-full-2x-s2.png"', '"windu-motion-v1-working-b-full-2x-s2.png.edited"')], "is not in stock-state-history.json"),
    ("a pack folder is not in the ledger",
     [("NEWPACK", "", "{}")], "is not in the ledger"),
    ("a replaced map has no recorded hash",
     [(PIN, '    ("BundledCharacters/jedi-miles-windu", 27): "07db3f086b1595b779694c20f70e2e1de63822de71ec131eaa22758a0a51f7bf",\n', "")],
     "was replaced by a later map"),
]
# The one the local checks cannot see: the shipped 0.5.358 entry is rewritten to match a changed map and the number
# stays at 27. Disk, ledger and constant agree with each other; only the released tag disagrees.
TAG_MUTANT = ("a released entry is rewritten to match a changed map and the generation stays 27",
              [(PIN, ENTRY_28, ""),
               (PIN, f'(27, "{V1_HASH}")', f'(27, "{V2_HASH}")'),
               (CONTROLLER, "petDefaultArtGeneration = 28", "petDefaultArtGeneration = 27")],
              "control-v0.5.358 shipped BundledCharacters/jedi-miles-windu at generation 27")


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
