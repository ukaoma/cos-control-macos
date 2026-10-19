#!/usr/bin/env python3
"""0.5.328: the bundled Jedi Miles Windu pack is Jedi V1.5 (Miles 2026-10-19 12:56 CDT: "deploy these updated sprites for
our jedi. Needs to be the default for our future releases as well"). Baked from the V1.5 canary by
operations/personal/wk42_2026/miles-windu-refinement/installation-v1-5 in the COS repo (render-receipt-windu.json,
manifest sha256 279622b1..., pack sha256 0fd03b11...). V14 timing-v2 is the rollback.

Pins, each checked once on the real tree and then required to FAIL on in-memory mutations:
  - every file the shipped map names, by sha256, PNG size, colour type and byte count, and the map itself;
  - the casts: four on Session 1 (working), three on duel, trio and swarm, their handoffs and flat names;
  - the retained V14 strips the upgrade compares installed bytes against, and the upgrade wiring in the source
    (V14 strips recognized as stock, working rotation loaded, art generation 23, no file removal on the way);
  - no stale V14 cast layer or orphan V1.5 file ships, and scripts/build-release.sh copies the flat files.

    python3 Tests/jedi-v1-5-pack-pins.py <root> [-v]   (-v names the check that caught each mutant)
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import re
import struct
import sys
from typing import Callable

V15 = "session-pet-windu-v1-5-"
MANIFEST_SHA = "279622b17494fa31ad88cdcc1055ef820351929cc0a61d653eb8b1a1d0fe104a"
# name: (sha256, width, height, bytes). The V1.5 strips and cast layers, then the three V14 ambient strips V1.5 keeps.
PINNED = {
    V15 + "attention.png": ("297ac39bb832362664a16655f36a7ad2a6775791921304d18bc5b2061810ac3c", 2178, 256, 184160),
    V15 + "done.png": ("e88249bd15543a6ae8f221b5018d242ee21b1968dd9b7099d8b2b7ad447f2751", 1386, 256, 182079),
    V15 + "duel-a-body.png": ("979d8e5779d80effe3f3096c5147b7b257a44d5d1bfe3dc4529d3f323820b9b4", 11248, 256, 1131083),
    V15 + "duel-a-entry.png": ("ef29bb749df4a0694aa1976740c364f0d5fd96daa2fb20a2980c6f28a7e5fd39", 11248, 256, 98604),
    V15 + "duel-a-full.png": ("412f8a82e82c2e84ccd36cb8d14aa1f672df565a2d78298a4d67bbff8f139a34", 11248, 256, 1210352),
    V15 + "duel-b-body.png": ("5769384e70df5cf241173ffe6a558b3a3bc0b8c75b177b77e47f975aaaa859c8", 11248, 256, 1106797),
    V15 + "duel-b-entry.png": ("efc44a4eaabe7d2e0ea315331d9e9a29b26599e36fea163663d9b5f7731c1814", 11248, 256, 118095),
    V15 + "duel-b-full.png": ("4245770b2fd8ddbb151982d2499caf9059a0e0252572b96706784bd0d8186b0c", 11248, 256, 1203253),
    V15 + "duel-c-body.png": ("f1aee9181b3dfb7f3e2d51b9bdaa6d936d7a797d68fe92cc4b5d26829f090efb", 11248, 256, 1131264),
    V15 + "duel-c-entry.png": ("677696fa3cabadacb905a7fde6a5b53b1c5ab46afee1b7ca7d291af0552c2cba", 11248, 256, 109404),
    V15 + "duel-c-full.png": ("708b2e5e7feacedbc072e21e7c3373d8bedc6e2781126693a7fc4ec690a15498", 11248, 256, 1218978),
    V15 + "error.png": ("817e9c1ee474d4ae94a50c13fa3caa802b2e9647a1ade411221f6375ac050d66", 1792, 256, 145573),
    V15 + "swarm-a-body.png": ("0459260fd0778727b9e688b34a0cf99ad3179a25b1c0713e67856be676017f54", 19904, 256, 2126692),
    V15 + "swarm-a-entry.png": ("17bce1b359d09a2ede5011b62ecbc8ecbfeb71df37ff4eb018791cb8a9140bb0", 19904, 256, 189595),
    V15 + "swarm-a-full.png": ("da2b255297952b84bbd23368f9364712ce8622e99e7b00c82e2f6e19c3251af6", 19904, 256, 2275939),
    V15 + "swarm-b-body.png": ("61bc36e8007d9efa879a48b0d5035e05f5ab0dc9bfb3795abd337756555cf378", 19904, 256, 2063048),
    V15 + "swarm-b-entry.png": ("52bc7ab78b0e72397e77d9f6dcb63792b1eedb73d44b1c00d0d84c0ca6583cda", 19904, 256, 187167),
    V15 + "swarm-b-full.png": ("878e6e450c363ca150cccc35c863c2cffa43a69d7f25d2516a6b8253671cd2bd", 19904, 256, 2208170),
    V15 + "swarm-c-body.png": ("90aa60767c2c0cba8f04a2433b919d49b1aff8d1f54ada9df483b0f43ce17f3c", 19904, 256, 2121831),
    V15 + "swarm-c-entry.png": ("c095f5d4dcc9e6f52f2e7bb4b31401a7343b917f88a5bbfd1c0d0fa42680a3f9", 19904, 256, 197747),
    V15 + "swarm-c-full.png": ("1615bf50488bb22b33eb75fadc393505dad3d8f850152e02f995d9e3d33a92ca", 19904, 256, 2278086),
    V15 + "trio-a-body.png": ("1d2d2f900ef4cd1e429d04a20ab1aa4be1d9c0d98e2217b8c43d5c12dde86d53", 12298, 256, 1448997),
    V15 + "trio-a-entry.png": ("90c2fada061dd9152aea3a0aeac40778eadba521e882031a6930c118c52e5b39", 12298, 256, 207312),
    V15 + "trio-a-full.png": ("5994b0ced43da7a5792b0ae061add8274d9606114553b433b4334da6b80874e1", 12298, 256, 1586709),
    V15 + "trio-b-body.png": ("b7e0d541a81f50e9665cb61c53794bc42145ea6faebbeae061c51874d9c049a3", 12298, 256, 1357211),
    V15 + "trio-b-entry.png": ("9dca6d1fcc086417846634211bf06934db933a78d02f66b2bbf51dca8765d375", 12298, 256, 191687),
    V15 + "trio-b-full.png": ("cd7845da191f6dcfac1dee404717ded9896fc64e9c1cce6c8065dabb9551d025", 12298, 256, 1491594),
    V15 + "trio-c-body.png": ("54e24ad9ca4a41c8a3fa7faa2c412369408191492613a7da01f6f914339343b7", 12298, 256, 1438637),
    V15 + "trio-c-entry.png": ("fb3160808c6f37d8ed1ec1ee53061e959b453a238a9fc34aa37787d431a59e11", 12298, 256, 217862),
    V15 + "trio-c-full.png": ("88f3a4ce2165dcb7304cbe888a1d3abf24d982e0eeb4d726c88bcafec50a4acd", 12298, 256, 1586999),
    V15 + "working-a-body.png": ("ea3930aa08c188c5ec691a0f427e314b931722e89766f507eada01769c1e5b19", 13984, 256, 1006902),
    V15 + "working-a-entry.png": ("db8e15e81e2502758bb933ed04b9c8a27a2c48e8c4efdb5cd136ff8775359724", 13984, 256, 13968),
    V15 + "working-a-full.png": ("ea3930aa08c188c5ec691a0f427e314b931722e89766f507eada01769c1e5b19", 13984, 256, 1006902),
    V15 + "working-b-body.png": ("d279cbf68b15a38695da14926f4c5f8d67a654dfc61335951f15c04f25065304", 13984, 256, 1058975),
    V15 + "working-b-entry.png": ("db8e15e81e2502758bb933ed04b9c8a27a2c48e8c4efdb5cd136ff8775359724", 13984, 256, 13968),
    V15 + "working-b-full.png": ("d279cbf68b15a38695da14926f4c5f8d67a654dfc61335951f15c04f25065304", 13984, 256, 1058975),
    V15 + "working-c-body.png": ("3679c33b888481d9a588837416f6ad10f5598a82ad1348807a440867890e4f6c", 13984, 256, 1040672),
    V15 + "working-c-entry.png": ("db8e15e81e2502758bb933ed04b9c8a27a2c48e8c4efdb5cd136ff8775359724", 13984, 256, 13968),
    V15 + "working-c-full.png": ("3679c33b888481d9a588837416f6ad10f5598a82ad1348807a440867890e4f6c", 13984, 256, 1040672),
    V15 + "working-d-body.png": ("920af6b9780e09611a9bc3c21878b7f29ca6a53a36f70565a654335c69d2e2b0", 13984, 256, 1024617),
    V15 + "working-d-entry.png": ("db8e15e81e2502758bb933ed04b9c8a27a2c48e8c4efdb5cd136ff8775359724", 13984, 256, 13968),
    V15 + "working-d-full.png": ("920af6b9780e09611a9bc3c21878b7f29ca6a53a36f70565a654335c69d2e2b0", 13984, 256, 1024617),
    "session-pet-idle-cutouts-v2.png": ("f16814c7139b1d72009c755497f9e97b9100635c86cde123bbc232565ae6e33c", 664, 256, 146417),
    "session-pet-patrol-polish-v3.png": ("c1340d57fd902522cc686664b225358b14a9d3246eada3e98221fbedd9efc4c6", 1024, 256, 146340),
    "session-pet-waiting-release-v1.png": ("e885beb423f2e8febd348d0a8fc566ed2e20da6c1b78bbe33efc3a9aa6b765f3", 1067, 256, 147023),
}
# The V14 timing-v2 Sessions 1 to 4. Not in the map any more; the upgrade compares an installed V14 against these bytes.
RETAINED_V14 = {
    "session-pet-working-v13.png": ("4df56c59db80b8041de5a6f24a56eeadbaa26afca23be4af1c93b702ff5c2c52", 46),
    "session-pet-duel-v13.png": ("e0d1fc28f3eb8c89b74514687272d7290fe0a56577f14ee064f91f35af50b51d", 37),
    "session-pet-trio-v13.png": ("397e277d2c566ae9e8f418ec5af850420aeac1dd95f824beff1b6f330b1b0096", 43),
    "session-pet-swarm-v13.png": ("a9a16a873f6098219b9b5b26f8f9e9deebf4e33cb194e8e83a577ac2417186cd", 64),
}
# pose: (frames, interval, cell width, handoff, casts). Cell width is the strip width over its frames.
CASTS = {"working": (46, 0.08, 304, 37, "abcd"), "duel": (37, 0.08, 304, 28, "abc"),
         "trio": (43, 0.08, 286, 31, "abc"), "swarm": (64, 0.08, 311, 55, "abc")}
SIGNALS = {"attention": (18, 0.12, 121), "done": (14, 0.14, 99), "error": (8, 0.14, 224)}


class Fail(AssertionError):
    pass


def need(ok: bool, why: str) -> None:
    if not ok:
        raise Fail(why)


def png(data: bytes, name: str) -> tuple[int, int, int]:
    need(data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR", f"{name} is not a PNG")
    width, height, _, colour = struct.unpack(">IIBB", data[16:26])
    return width, height, colour


def validate(map_bytes: bytes, read: Callable[[str], bytes | None], listing: set[str], release: str, models: str, controller: str,
             pin_map: bool = True) -> int:
    # Map mutants run with pin_map=False so each structural check below must catch them on its own.
    need(not pin_map or hashlib.sha256(map_bytes).hexdigest() == MANIFEST_SHA, "the shipped map drifted from the approved V1.5 map")
    poses = json.loads(map_bytes)["poses"]
    need(sorted(p for p, row in poses.items() if "rotation" in row) == sorted(CASTS),
         "casts rotate on working, duel, trio and swarm, and on no other pose")
    referenced: list[str] = []
    for row in poses.values():
        referenced.append(row["file"])
        for variant in row.get("rotation", {}).get("variants", []):
            referenced += [variant["file"], variant["bodyFile"], variant["entryFile"]]
    for name in referenced:
        need("/" not in name and name.endswith(".png"), f"{name} must be a flat .png (the release copies DefaultPet/*.png only)")
        need(name in listing, f"the map names {name}, which is not in Resources/DefaultPet")
    need('cp "$ROOT/Resources/DefaultPet/"*.png "$ROOT/Resources/DefaultPet/"*.json' in release,
         "scripts/build-release.sh ships DefaultPet's flat .png and .json files")
    for pose, (frames, interval, cell, handoff, casts) in CASTS.items():
        row = poses[pose]
        need(row["frames"] == frames and row["interval"] == interval, f"{pose} plays {frames} frames at {interval}s")
        rotation = row["rotation"]
        need(rotation.get("version") == 1 and rotation.get("handoffFrame") == handoff and "seed" not in rotation,
             f"{pose} hands off at frame {handoff}, unseeded")
        variants = rotation.get("variants", [])
        need([v["id"] for v in variants] == [f"{pose}-{c}" for c in casts], f"{pose} casts are {pose}-{', -'.join(casts)} in order")
        for v in variants:
            for key, kind in (("file", "full"), ("bodyFile", "body"), ("entryFile", "entry")):
                need(v[key] == f"{V15}{v['id']}-{kind}.png", f"{pose} {v['id']} {key} is {v[key]}")
        need(row["file"] == variants[0]["file"], f"{pose} falls back to its first cast's full strip")
        need(PINNED[row["file"]][1] == frames * cell, f"{pose} is {frames} cells of {cell} px")
    for pose, (frames, interval, cell) in SIGNALS.items():
        row = poses[pose]
        need(row == {"file": f"{V15}{pose}.png", "frames": frames, "interval": interval}, f"{pose} is the V1.5 {frames}-frame signal")
        need(PINNED[row["file"]][1] == frames * cell, f"{pose} is {frames} cells of {cell} px")
    need(poses["working"].get("renderScale") == 0.75 and poses["idle"].get("renderScale") == 1.0, "pack-owned scales are V14's")
    for name, (digest, width, height, size) in PINNED.items():
        data = read(name)
        need(data is not None, f"{name} is missing")
        need(png(data, name) == (width, height, 6), f"{name} must be an RGBA PNG {width}x{height}")
        need(len(data) == size, f"{name} is {len(data)} bytes, pinned {size}")
        need(hashlib.sha256(data).hexdigest() == digest, f"{name} drifted from the approved V1.5 bytes")
    need(set(referenced) == set(PINNED), "the map names exactly the pinned files")
    need({n for n in listing if n.startswith(V15)} == {n for n in PINNED if n.startswith(V15)}, "no orphan V1.5 file ships")
    need(not any(n.startswith("session-pet-windu-v14-timing-v2-") for n in listing),
         "V14's 27 cast layers no longer ship (installed copies are never deleted; the rollback lives in the COS repo)")
    for name, (digest, frames) in RETAINED_V14.items():
        data = read(name)
        need(data is not None and hashlib.sha256(data).hexdigest() == digest, f"retained V14 strip {name} drifted or is missing")
        need(f'("{name}", {frames}),' in models, f"the upgrade does not recognize an installed V14 {name} at {frames} frames")
    need("for pose in [PetSpritePose.working, .duel, .trio, .swarm] {" in models, "Session 1 casts load (loadRotations covers working)")
    need(int(re.search(r"petDefaultArtGeneration = (\d+)", controller).group(1)) >= 23, "art generation 23 runs the V1.5 upgrade once")
    refresh = models.split("static func refreshRecognizedBundledDefault(", 1)[1].split("static func remove(from", 1)[0]
    need("removeItem" not in refresh and "removeAll" not in refresh, "the stock upgrade never deletes a file")
    return len(PINNED)


def main() -> None:
    root = pathlib.Path(next((a for a in sys.argv[1:] if a != "-v"), "."))
    folder = root / "Resources/DefaultPet"
    map_bytes = (folder / "session-pet-states.json").read_bytes()
    listing = {p.name for p in folder.iterdir() if p.is_file()}
    release = (root / "scripts/build-release.sh").read_text()
    models = (root / "Sources/Models.swift").read_text()
    controller = (root / "Sources/ControllerModel.swift").read_text()
    cache: dict[str, bytes | None] = {}

    def read(name: str) -> bytes | None:
        if name not in cache:
            path = folder / name
            cache[name] = path.read_bytes() if path.is_file() else None
        return cache[name]

    pinned = validate(map_bytes, read, listing, release, models, controller)

    def edited(edit: Callable[[dict], None]) -> bytes:
        state = json.loads(map_bytes)
        edit(state)
        return (json.dumps(state, indent=2, sort_keys=True) + "\n").encode()

    def flip(name: str) -> Callable[[str], bytes | None]:
        return lambda n: (read(n)[:-1] + bytes([read(n)[-1] ^ 1])) if n == name else read(n)

    def resize(name: str) -> Callable[[str], bytes | None]:
        return lambda n: read(n)[:16] + struct.pack(">I", PINNED[name][1] + 1) + read(n)[20:] if n == name else read(n)

    base = (map_bytes, read, listing, release, models, controller)

    def with_(**kw):
        order = ["map_bytes", "read", "listing", "release", "models", "controller"]
        args = dict(zip(order, base))
        args.update(kw)
        return tuple(args[k] for k in order)

    v14_layer = "session-pet-windu-v14-timing-v2-duel-a-full.png"
    mutants = [
        ("a cast layer's bytes change", with_(read=flip(V15 + "swarm-c-entry.png"))),
        ("a Session 1 layer's width changes", with_(read=resize(V15 + "working-b-full.png"))),
        ("a signal strip's bytes change", with_(read=flip(V15 + "attention.png"))),
        ("an ambient strip gains a byte", with_(read=lambda n: read(n) + b"\0" if n == "session-pet-waiting-release-v1.png" else read(n))),
        ("a pinned layer is missing", with_(read=lambda n: None if n == V15 + "trio-b-body.png" else read(n),
                                            listing=listing - {V15 + "trio-b-body.png"})),
        ("the map's bytes change (same content, other indent)", with_(map_bytes=json.dumps(json.loads(map_bytes), indent=4).encode())),
        ("Session 1 loses a cast", with_(map_bytes=edited(lambda s: s["poses"]["working"]["rotation"]["variants"].pop()))),
        ("Session 1 loses its rotation", with_(map_bytes=edited(lambda s: s["poses"]["working"].pop("rotation")))),
        ("a fourth trio cast", with_(map_bytes=edited(lambda s: s["poses"]["trio"]["rotation"]["variants"].append(
            dict(s["poses"]["trio"]["rotation"]["variants"][0], id="trio-d"))))),
        ("a rotation on idle", with_(map_bytes=edited(lambda s: s["poses"]["idle"].__setitem__("rotation", s["poses"]["duel"]["rotation"])))),
        ("a layer named in a subfolder", with_(map_bytes=edited(lambda s: s["poses"]["duel"]["rotation"]["variants"][0].__setitem__(
            "file", "rotation/v1-5/duel-a-full.png")))),
        ("the swarm handoff drifts", with_(map_bytes=edited(lambda s: s["poses"]["swarm"]["rotation"].__setitem__("handoffFrame", 54)))),
        ("attention goes back to V12's 13 frames", with_(map_bytes=edited(lambda s: s["poses"]["attention"].update(
            file="session-pet-attention-retime-v12-v1.png", frames=13, interval=0.14)))),
        ("a seeded rotation ships", with_(map_bytes=edited(lambda s: s["poses"]["duel"]["rotation"].__setitem__("seed", 7)))),
        ("an orphan V1.5 file ships", with_(listing=listing | {V15 + "duel-d-full.png"})),
        ("a V14 cast layer ships again", with_(listing=listing | {v14_layer})),
        ("a retained V14 strip changes", with_(read=flip("session-pet-trio-v13.png"))),
        ("the upgrade forgets V14 Session 1", with_(models=models.replace('("session-pet-working-v13.png", 46),', "", 1))),
        ("the loader drops Session 1 casts", with_(models=models.replace(
            "for pose in [PetSpritePose.working, .duel, .trio, .swarm] {", "for pose in [PetSpritePose.duel, .trio, .swarm] {", 1))),
        ("the art generation stays at 22", with_(controller=re.sub(r"petDefaultArtGeneration = \d+", "petDefaultArtGeneration = 22", controller))),
        ("the upgrade deletes a file", with_(models=models.replace(
            "            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)\n            for story in stories {",
            "            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)\n"
            "            try? fileManager.removeItem(at: directory)\n            for story in stories {", 1))),
        ("the release copies subfolders only", with_(release=release.replace('"$ROOT/Resources/DefaultPet/"*.png ', ""))),
    ]
    for name, args in mutants:
        # A mutant must land: at least one input differs from the real tree (a read mutant swaps the reader for one
        # that changes a file that exists), or a check that cannot fail would be reported as a catch.
        changed = [i for i, (a, b) in enumerate(zip(args, base)) if a is not b and a != b]
        need_landed = changed != [] and all(i != 1 or any(args[1](n) != read(n) for n in PINNED.keys() | RETAINED_V14.keys())
                                            for i in changed)
        if not need_landed:
            sys.exit(f"jedi-v1-5 pins: mutant '{name}' did not land (it changes nothing the checks read)")
        structural = args[0] != map_bytes and "other indent" not in name
        try:
            validate(*args, pin_map=not structural)
        except Fail as caught:
            if "-v" in sys.argv:
                print(f"  caught {name}: {caught}")
            continue
        sys.exit(f"jedi-v1-5 pins: mutant '{name}' was not caught")
    print(f"jedi-v1-5 pins: {pinned} files pinned (map {MANIFEST_SHA[:8]}), 4 Session 1 casts and 3 on duel, trio and swarm, "
          f"4 retained V14 strips and the upgrade wiring; {len(mutants)} mutants each landed and caught")


if __name__ == "__main__":
    main()
