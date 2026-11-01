#!/usr/bin/env python3
"""A bundled pet pack's state map and petDefaultArtGeneration move together.

0.5.360: Windu Motion V2 shipped in the bundle with the generation left at 27. Installs already at 27 skip the upgrade
block in ControllerModel.loadPetSprite(), so nobody on Motion V1 ever received it, and the only test (">= 26") passed.

The ledger below records, per bundled pack, the sha256 of its session-pet-states.json from the generation it first took
effect. The pin fails when:
  - a state map on disk is not the last ledger entry (it changed: add an entry at a higher generation),
  - the highest ledger generation is above the constant in ControllerModel.swift (the constant did not move),
  - the generations are not strictly increasing,
  - a released tag (control-v*) carries bytes the ledger does not give for that tag's own generation (a shipped entry
    was rewritten, or the bytes changed while the number did not).
The tag check reads git; with no tags in the checkout it says so and checks the rest.

Usage: python3 Tests/pet-art-generation-pins.py <repo root>
Environment: COS_PIN_GIT_ROOT names the checkout whose tags are read (the mutation lane runs on a scratch copy).
"""
import hashlib
import os
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
git_root = pathlib.Path(os.environ.get("COS_PIN_GIT_ROOT", str(root))).resolve()

# pack folder (under Resources/) -> [(generation, sha256 of its session-pet-states.json from that generation on)]
LEDGER = {
    "BundledCharacters/jedi-elara-vale": [(27, "c03ba845418c9a8d4a1d154f39f54f5b18828f9a0fc4f10203b50c0df70b29ea")],
    "BundledCharacters/jedi-nia-solari": [(27, "78ab44b6d921bc54278694e0ca99c1157b70a8790fe60fe38ea63647a1b1c989")],
    "BundledCharacters/jedi-rowan-vale": [(27, "a9bcdc690b011d7f4d63ab9c39037acc82856f87787e77d20d9a44d73c2952b9")],
    "BundledCharacters/jedi-miles-windu": [
        (27, "2ba8634a87ccbc0ec37bb10a383e4ffd76aba30122a31df120516f70513c39d1"),  # Windu Motion V1, 0.5.350 to 0.5.358
        (28, "0292c01a15077ee7c28d61fb7d82b86b6959c2137fd55a30dc9375f18c7a2313"),  # Windu Motion V2, 0.5.360
    ],
    "DefaultPet": [(27, "af4fc61df77344d955633563cef7b0c55fd7dc39a02753c443d26d9f16f4d134")],
}


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def generation_in(source: str) -> "int | None":
    found = re.search(r"petDefaultArtGeneration = (\d+)", source)
    return int(found.group(1)) if found else None


def effective(entries, generation):
    """The hash the ledger gives a pack at a generation: its latest entry at or below it, or None before the first."""
    hashes = [digest for entry_generation, digest in entries if entry_generation <= generation]
    return hashes[-1] if hashes else None


constant = generation_in((root / "Sources/ControllerModel.swift").read_text())
if constant is None:
    fail("the art-generation constant is gone from ControllerModel.swift")

for pack, entries in LEDGER.items():
    generations = [generation for generation, _ in entries]
    if generations != sorted(set(generations)):
        fail(f"{pack}: ledger generations must strictly increase")
    state = root / "Resources" / pack / "session-pet-states.json"
    if not state.is_file():
        fail(f"{pack}: session-pet-states.json is missing")
    now = hashlib.sha256(state.read_bytes()).hexdigest()
    if now != entries[-1][1]:
        fail(f"{pack}: session-pet-states.json changed. Raise petDefaultArtGeneration above {constant} and add a ledger "
             f"entry for it in this file, or installs already at {constant} never receive the new pack.")
    if generations[-1] > constant:
        fail(f"{pack}: the ledger reaches generation {generations[-1]} but petDefaultArtGeneration is {constant}. "
             f"Installs below {generations[-1]} would stay on the old pack.")

checked = []
tags = subprocess.run(["git", "-C", str(git_root), "tag", "--list", "control-v*"], capture_output=True, text=True)
for tag in sorted(tags.stdout.split()) if tags.returncode == 0 else []:
    shown = subprocess.run(["git", "-C", str(git_root), "show", f"{tag}:Sources/ControllerModel.swift"],
                           capture_output=True, text=True)
    tag_generation = generation_in(shown.stdout) if shown.returncode == 0 else None
    if tag_generation is None:
        continue
    for pack, entries in LEDGER.items():
        blob = subprocess.run(["git", "-C", str(git_root), "show", f"{tag}:Resources/{pack}/session-pet-states.json"],
                              capture_output=True)
        if blob.returncode != 0:
            continue
        shipped = hashlib.sha256(blob.stdout).hexdigest()
        expected = effective(entries, tag_generation)
        if expected is None:
            continue
        if shipped != expected:
            fail(f"{tag} shipped {pack} at generation {tag_generation} with bytes the ledger does not give for that "
                 f"generation. A shipped entry was rewritten, or the bytes changed without the number.")
    checked.append(f"{tag}@{tag_generation}")

print(f"PASS: generation {constant} matches {len(LEDGER)} pack state maps; "
      + (f"released tags checked: {', '.join(checked)}" if checked else "no control-v* tag in this checkout, tag check skipped"))
