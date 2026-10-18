#!/usr/bin/env python3
"""0.5.325: the bundled Jedi Miles Windu pack is V14 timing-v2 (Miles 2026-10-17, installation-v14-timing-v2 in the COS
repo, approved map sha256 8016a0c9...). Pins every V14 file the map adds by sha256, PNG size, colour type and byte
count, the three shuffled casts on duel, trio and swarm only, and that the shipped map names only flat files that exist
in Resources/DefaultPet and that scripts/build-release.sh copies (it copies DefaultPet/*.png and *.json, no subfolders).

The values were computed from the flattened files and match the pack's installation-receipt.json (sha256 and bytes of
each rotation/v14-timing-v2/ layer) and its candidate-pack strips byte for byte. Each check runs once on the real tree,
then must FAIL on in-memory mutations of it, so a check that cannot fail is caught here.

    python3 Tests/windu-v14-pack-pins.py <root> [-v]   (-v names the check that caught each mutant)
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import struct
import sys
from typing import Callable

LAYER = "session-pet-windu-v14-timing-v2-"
# name: (sha256, width, height, bytes). Strips first, then the 27 cast layers (full, body, entry per cast).
PINNED = {
    "session-pet-working-v13.png": ("4df56c59db80b8041de5a6f24a56eeadbaa26afca23be4af1c93b702ff5c2c52", 13984, 256, 1164389),
    "session-pet-duel-v13.png": ("e0d1fc28f3eb8c89b74514687272d7290fe0a56577f14ee064f91f35af50b51d", 11248, 256, 1137789),
    "session-pet-trio-v13.png": ("397e277d2c566ae9e8f418ec5af850420aeac1dd95f824beff1b6f330b1b0096", 12298, 256, 1366090),
    "session-pet-swarm-v13.png": ("a9a16a873f6098219b9b5b26f8f9e9deebf4e33cb194e8e83a577ac2417186cd", 19904, 256, 1946767),
    LAYER + "duel-a-full.png": ("7fc390e1141ec5831bf2c6e57c31f7961c2d298ff4571dae9236b9a80f3868b7", 11248, 256, 1284545),
    LAYER + "duel-a-body.png": ("a565f3d631840ff4a8045c2d8676b66e896e6a29a2141f00b808ad5e3a59b9c0", 11248, 256, 1190996),
    LAYER + "duel-a-entry.png": ("70455061eb306e335d4a9d186967e617c7803e38829b856ee5118b614b000d25", 11248, 256, 113179),
    LAYER + "duel-b-full.png": ("fbc00ee6b24b43125107ceb077a11baf7f890319db8a660d4c7d14b930fad1a6", 11248, 256, 1292778),
    LAYER + "duel-b-body.png": ("34d73471731cd8ee44716fed2821535b6d5d56940bfef166059c9571b4fe950f", 11248, 256, 1186878),
    LAYER + "duel-b-entry.png": ("720c1a62b3933f5a999222c0fad3380a3eb6b195b2f0d80ea0b4a64be5c00c8e", 11248, 256, 129609),
    LAYER + "duel-c-full.png": ("3cb851554e2ecc1ecf77c14f8f1f6892258e477b299f53bce25b7be5d2213295", 11248, 256, 1312300),
    LAYER + "duel-c-body.png": ("61d4d452c0c30ff2e602829ee25a3d888df8faab46f2a9e3d3e34fc5e6ebd3df", 11248, 256, 1202342),
    LAYER + "duel-c-entry.png": ("06b48149d35469a9608c2602713460a662eae11292503799b3a079bdb166cb23", 11248, 256, 131852),
    LAYER + "trio-a-full.png": ("791ce5210f4a6f8ea28cb28d0285dfe704779522f615c906716d134ba9915b69", 12298, 256, 1936370),
    LAYER + "trio-a-body.png": ("b0f646ac9db843aadf4122ea1690e39ae9c532d80d05fcb7ad3f8a8df9162d9f", 12298, 256, 1758452),
    LAYER + "trio-a-entry.png": ("11ccec8924ade25214c2f0548e6dfc64a008de012b07bb707cb21e881802f9db", 12298, 256, 234609),
    LAYER + "trio-b-full.png": ("d08650c8e8d624f424a77b7949864ce4a11784c4c7149ed5ef2bbc016d3a37da", 12298, 256, 1819672),
    LAYER + "trio-b-body.png": ("b63ff686279353dfa1633cb8357afdf1dfb029624424cd3df0e4559928a34990", 12298, 256, 1643731),
    LAYER + "trio-b-entry.png": ("48007d101ea4bc2360f5e5925458dad07356d114f41d4e03cf724e7ee3713282", 12298, 256, 220224),
    LAYER + "trio-c-full.png": ("1913f4cdcfee07d3bb50ecaeb3481990b17505c8bfd7ae846a94aa5eb6ee5a63", 12298, 256, 1982730),
    LAYER + "trio-c-body.png": ("a689774b2c54df27921a242b79f08e7bd3309dc5c6b1091308e948a989fa49a2", 12298, 256, 1788458),
    LAYER + "trio-c-entry.png": ("e714b02bc47fb802fc1d2817b4c24d620b70b6a1b12392ec1513f29390be07ca", 12298, 256, 252133),
    LAYER + "swarm-a-full.png": ("1a500684f9a9d692e7bad7b958f01ff6e58826b1e779b6a0220885bf9ed8131a", 19904, 256, 2508636),
    LAYER + "swarm-a-body.png": ("0098e6085ecd1c6b138c8f8d7624f6a008a57aa48c979c43e8749fec127b28f1", 19904, 256, 2339957),
    LAYER + "swarm-a-entry.png": ("fdb23ca8ead720c3e34ec3487cd4ff9b789a53ddf0df136e7d9dee944e4c0bb8", 19904, 256, 214798),
    LAYER + "swarm-b-full.png": ("092264f1d43fe81b774bdd5b6d43fae5ba67a9e579a1091c2c1aaac875893575", 19904, 256, 2445159),
    LAYER + "swarm-b-body.png": ("df8ca72dbb86dfe7b6442a41754c698f2b58736cd2043244980e40a3de6d9f87", 19904, 256, 2277432),
    LAYER + "swarm-b-entry.png": ("87e5349da6cbeab631a35095fd3aa49b6dcaa899af9ee3dba7ab29040e60ac2f", 19904, 256, 212879),
    LAYER + "swarm-c-full.png": ("ac80c6a4cc583d1b84765b82db8c993c5b3c4c2a528077e59fb7cfa5e26cfe16", 19904, 256, 2541549),
    LAYER + "swarm-c-body.png": ("4e21a51105f8d624e609136ee6381262c8eba529124e83fb0b09f758ca7f15d1", 19904, 256, 2361392),
    LAYER + "swarm-c-entry.png": ("b3e8fe9c5a496bb8852e847cc0cc8830b8c15b66e4909567817420de483c9d12", 19904, 256, 228782),
}
# pose: (strip, frames, cell width, handoff frame). Cell width is the strip width over its frames.
CASTS = {"duel": ("session-pet-duel-v13.png", 37, 304, 28), "trio": ("session-pet-trio-v13.png", 43, 286, 31),
         "swarm": ("session-pet-swarm-v13.png", 64, 311, 55)}


class Fail(AssertionError):
    pass


def need(ok: bool, why: str) -> None:
    if not ok:
        raise Fail(why)


def png(data: bytes, name: str) -> tuple[int, int, int]:
    need(data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR", f"{name} is not a PNG")
    width, height, _, colour = struct.unpack(">IIBB", data[16:26])
    return width, height, colour


def validate(state: dict, read: Callable[[str], bytes | None], listing: set[str], release: str) -> int:
    poses = state["poses"]
    need(sorted(p for p, row in poses.items() if "rotation" in row) == sorted(CASTS),
         "a three-cast rotation on duel, trio and swarm, and on no other pose")
    referenced: list[str] = []
    for pose, row in poses.items():
        referenced.append(row["file"])
        for variant in row.get("rotation", {}).get("variants", []):
            referenced += [variant["file"], variant["bodyFile"], variant["entryFile"]]
    for name in referenced:
        need("/" not in name and name.endswith(".png"), f"{name} must be a flat .png (the release copies DefaultPet/*.png only)")
        need(name in listing, f"the map names {name}, which is not in Resources/DefaultPet")
    need('cp "$ROOT/Resources/DefaultPet/"*.png "$ROOT/Resources/DefaultPet/"*.json' in release,
         "scripts/build-release.sh ships DefaultPet's flat .png and .json files")
    for pose, (strip, frames, cell, handoff) in CASTS.items():
        row = poses[pose]
        need(row["file"] == strip and row["frames"] == frames, f"{pose} plays {strip} at {frames} frames")
        rotation = row["rotation"]
        need(rotation.get("version") == 1 and rotation.get("handoffFrame") == handoff, f"{pose} hands off at frame {handoff}")
        variants = rotation.get("variants", [])
        need(len(variants) == 3, f"{pose} rotates exactly three casts, got {len(variants)}")
        need([v["id"] for v in variants] == [f"{pose}-{c}" for c in "abc"], f"{pose} casts are {pose}-a, -b, -c in order")
        for v in variants:
            for key, kind in (("file", "full"), ("bodyFile", "body"), ("entryFile", "entry")):
                need(v[key] == f"{LAYER}{v['id']}-{kind}.png", f"{pose} {v['id']} {key} is {v[key]}")
        need(PINNED[strip][1] == frames * cell, f"{strip} is {frames} cells of {cell} px")
    need(poses["working"]["file"] == "session-pet-working-v13.png" and poses["working"]["frames"] == 46,
         "One (working) is the approved V13 sprint, 46 frames")
    for name, (digest, width, height, size) in PINNED.items():
        data = read(name)
        need(data is not None, f"{name} is missing")
        need(png(data, name) == (width, height, 6), f"{name} must be an RGBA PNG {width}x{height}")
        need(len(data) == size, f"{name} is {len(data)} bytes, pinned {size}")
        need(hashlib.sha256(data).hexdigest() == digest, f"{name} drifted from the approved V14 bytes")
    layers = {n for n in referenced if n.startswith(LAYER)}
    need(len(layers) == 27 and layers == {n for n in PINNED if n.startswith(LAYER)}, "the map names exactly the 27 pinned cast layers")
    need({n for n in listing if n.startswith(LAYER)} == layers, "no V14 cast layer ships that the map does not name")
    return len(PINNED)


def main() -> None:
    root = pathlib.Path(next((a for a in sys.argv[1:] if a != "-v"), "."))
    folder = root / "Resources/DefaultPet"
    state = json.loads((folder / "session-pet-states.json").read_text())
    listing = {p.name for p in folder.iterdir() if p.is_file()}
    release = (root / "scripts/build-release.sh").read_text()
    cache: dict[str, bytes] = {}

    def read(name: str) -> bytes | None:
        if name not in cache:
            path = folder / name
            cache[name] = path.read_bytes() if path.is_file() else None
        return cache[name]

    pinned = validate(state, read, listing, release)

    def mutated(edit: Callable[[dict], None]) -> dict:
        copy = json.loads(json.dumps(state))
        edit(copy)
        return copy

    def flip(name: str) -> Callable[[str], bytes | None]:
        return lambda n: (read(n)[:-1] + bytes([read(n)[-1] ^ 1])) if n == name else read(n)

    def resize(name: str) -> Callable[[str], bytes | None]:
        def inner(n: str) -> bytes | None:
            data = read(n)
            return data[:16] + struct.pack(">I", 11249) + data[20:] if n == name else data
        return inner

    duel_a = LAYER + "duel-a-full.png"
    mutants = [
        ("a layer's bytes change", state, flip(LAYER + "swarm-c-entry.png"), listing, release),
        ("a layer's width changes", state, resize(duel_a), listing, release),
        ("a strip's bytes change", state, flip("session-pet-trio-v13.png"), listing, release),
        ("a layer gains a byte", state, lambda n: read(n) + b"\0" if n == LAYER + "duel-b-entry.png" else read(n), listing, release),
        ("a pinned layer is missing", state, lambda n: None if n == LAYER + "trio-b-body.png" else read(n),
         listing - {LAYER + "trio-b-body.png"}, release),
        ("a cast is dropped", mutated(lambda s: s["poses"]["trio"]["rotation"]["variants"].pop()), read, listing, release),
        ("a fourth cast is added", mutated(lambda s: s["poses"]["swarm"]["rotation"]["variants"].append(
            dict(s["poses"]["swarm"]["rotation"]["variants"][0], id="swarm-d"))), read, listing, release),
        ("a cast on a pose that has none", mutated(lambda s: s["poses"]["working"].__setitem__(
            "rotation", s["poses"]["duel"]["rotation"])), read, listing, release),
        ("a layer named in a subfolder", mutated(lambda s: s["poses"]["duel"]["rotation"]["variants"][0].__setitem__(
            "file", "rotation/v14-timing-v2/duel-a-full.png")), read, listing, release),
        ("a map file that does not exist", mutated(lambda s: s["poses"]["done"].__setitem__("file", "session-pet-done-v99.png")),
         read, listing, release),
        ("the handoff frame drifts", mutated(lambda s: s["poses"]["duel"]["rotation"].__setitem__("handoffFrame", 27)),
         read, listing, release),
        ("the trio frame count drifts", mutated(lambda s: s["poses"]["trio"].__setitem__("frames", 42)), read, listing, release),
        ("One goes back to the V12.6 run", mutated(lambda s: s["poses"]["working"].__setitem__(
            "file", "session-pet-working-run-slowed-v12-1.png")), read, listing, release),
        ("an orphan V14 layer ships", state, read, listing | {LAYER + "duel-d-full.png"}, release),
        ("the release copies subfolders only", state, read, listing, release.replace('"$ROOT/Resources/DefaultPet/"*.png ', "")),
    ]
    for name, s, r, l, rel in mutants:
        try:
            validate(s, r, l, rel)
        except Fail as caught:
            if "-v" in sys.argv:
                print(f"  caught {name}: {caught}")
            continue
        sys.exit(f"windu-v14 pins: mutant '{name}' was not caught")
    print(f"windu-v14 pins: {pinned} V14 files pinned (4 strips, 27 cast layers), 3 casts on duel, trio and swarm; "
          f"{len(mutants)} mutants each caught")


if __name__ == "__main__":
    main()
