#!/usr/bin/env python3
"""Mutation-tested wiring contract for Miles Windu's authored live stories."""

from __future__ import annotations

import json
import hashlib
import pathlib
import struct
import re
import sys


class ContractFailure(AssertionError):
    pass


def need(condition: bool, message: str) -> None:
    if not condition:
        raise ContractFailure(message)


def png_header(path: pathlib.Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    need(data[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} is not PNG")
    width, height, _, color_type = struct.unpack(">IIBB", data[16:26])
    return width, height, color_type


def validate(root: pathlib.Path, models: str, controller: str, motion: str, pet: str) -> None:
    # 0.5.328: Miles approved Version 15 (V15, 2026-10-19; installation-v1-5/bake_v15.py in the COS repo, map sha256
    # af4fc61d...) as the bundled pack: 1x strips here plus retina blocks (Tests/jedi-v15-pack-pins.py), four shuffled casts
    # on Session 1 (working) and three on duel, trio and swarm, the 18-frame attention and 14-frame done bridges (done in a
    # 199 pt cell so the saber is not cut) and the re-baked error, all flat names (the release copies DefaultPet without
    # subfolders). V14 timing-v2 (0.5.325 to 0.5.327) is the rollback; its four strips stay as retained stock.
    approved_state = {
        "attention": {"file": "windu-pack15-attention-1x.png", "frames": 18, "interval": 0.12},
        "done": {"file": "windu-pack15-done-1x.png", "frames": 14, "interval": 0.14},
        "duel": {"file": "windu-pack15-duel-a-full-1x.png", "frames": 37, "interval": 0.08},
        "error": {"file": "windu-pack15-error-1x.png", "frames": 8, "interval": 0.14},
        "idle": {"file": "session-pet-idle-cutouts-v2.png", "frames": 8, "renderScale": 1.0},
        "patrol": {"file": "session-pet-patrol-polish-v3.png", "frames": 8, "interval": 0.14},
        "swarm": {"file": "windu-pack15-swarm-a-full-1x.png", "frames": 64, "interval": 0.08},
        "trio": {"file": "windu-pack15-trio-a-full-1x.png", "frames": 43, "interval": 0.08},
        "waiting": {"file": "session-pet-waiting-release-v1.png", "frames": 11, "interval": 0.18},
        "working": {"file": "windu-pack15-working-a-full-1x.png", "frames": 46, "interval": 0.08, "renderScale": 0.75},
    }
    raw_rows = json.loads((root / "Resources/DefaultPet/session-pet-states.json").read_text())["poses"]
    state = {pose: {k: v for k, v in row.items() if k not in ("rotation", "retina")} for pose, row in raw_rows.items()}
    need(sorted(p for p, row in raw_rows.items() if "rotation" in row) == ["duel", "swarm", "trio", "working"],
         "V15 rotates casts on working, duel, trio and swarm, and nowhere else")
    handoffs = {"working": (37, "abcd"), "duel": (28, "abc"), "trio": (31, "abc"), "swarm": (55, "abc")}
    layers = []
    for pose, (handoff, casts) in handoffs.items():
        rotation = raw_rows[pose]["rotation"]
        need(rotation["version"] == 1 and rotation["handoffFrame"] == handoff, f"{pose} cast handoff drifted")
        need([v["id"] for v in rotation["variants"]] == [f"{pose}-{c}" for c in casts], f"{pose} casts drifted")
        strip_w, strip_h, _ = png_header(root / "Resources/DefaultPet" / raw_rows[pose]["file"])
        for variant in rotation["variants"]:
            for key, kind in (("file", "full"), ("bodyFile", "body"), ("entryFile", "entry")):
                name = variant[key]
                need(name == f"windu-pack15-{variant['id']}-{kind}-1x.png" and "/" not in name,
                     f"{pose} layer {name} must be flat (the release copies DefaultPet without subfolders)")
                w, h, ct = png_header(root / "Resources/DefaultPet" / name)
                need((w, h, ct) == (strip_w, strip_h, 6), f"{name} must be an RGBA layer the size of its {pose} strip")
                layers.append(name)
    need(len(set(layers)) == 39, "39 distinct cast layers (Session 1: 4 casts; Sessions 2 to 4: 3 each)")
    for pose, row in approved_state.items():
        need(state.get(pose) == row, f"{pose} does not point at the approved V15 strip, count, cadence and scale")
    need(set(state) == set(approved_state), "the shipped Miles map has a pose V15 does not declare")
    frame_cap = int(re.search(r"static let maxFrames = (\d+)", models).group(1))
    need(frame_cap == 256, "runtime frame limit must preserve complete Jedi recovery and entrance frames")
    # V15 widens done from 99 to 199: the A1 to A3 bridge sabers were cut at the 99 px edge, and the 0.5.329 re-fit of
    # the see-through F9 to F11 bridges (scaled up to the standing frames' height) needs the extra room (figure the same size).
    cell_widths = {"attention": 121, "done": 199, "duel": 304, "error": 224, "idle": 83, "patrol": 128,
                   "swarm": 311, "trio": 286, "waiting": 97, "working": 304}
    for pose, cell_width in cell_widths.items():
        row = state[pose]
        width, height, color_type = png_header(root / "Resources/DefaultPet" / row["file"])
        need(width == cell_width * row["frames"] and height == 256,
             f"{pose} story canvas/frame declaration drifted")
        need(color_type == 6, f"{pose} story must be a true RGBA PNG")
    approved_hashes = {
        "session-pet-working-one-droid-v15-2.png": "222d651fbef45d0832c2bbdeefb9865600227bd181c214dd2f9aa20e22c74c47",
        "session-pet-duel-two-droid-v15-2.png": "0ff6cf4aacee3b116d7effe40e632c55dcb824e92fd78160e0482bd08ba5fc80",
        "session-pet-trio-story-v15-2.png": "605e89b4b7400743e82c5b0f5f8eac8408b7ab596f19c49ff54990157eef5be7",
        "session-pet-swarm-story-v15-2.png": "ae2ae5e9f196e4d2b9892e3c076f361ac20aa8e33374486445c1ade0f83377ac",
        "session-pet-swarm-story-v15-3.png": "9cf09b01a930d8980eb765825fc2a12e2213289d7792df2249c26fcc8eec8b7e",
        "session-pet-swarm-story-v15-4.png": "a44550df21b81bd52604d18f5972697bc3e36bbf8823f7a9c34b5f0b1bf7d7ee",
        "session-pet-trio-story-v16.png": "bd0147eccacc01ef7cded5dd247cb35dbddc966c010d6bb0e1a0e0f6a227ccbd",
        "session-pet-trio-story-v17.png": "e08983b98e99220dd09885c4e68ef4061bdfd2b15756aae110de9fd7166b2bc1",
        "session-pet-swarm-story-v16.png": "80415ed66aa649763b42c3a934df40511e0ff258185b82b39a73fb8aca3211f3",
        # V12.6, the version-manifest.json sha256 of each reviewed file (retained V15/V16 stock above stays for
        # recognition: the refresh compares installed bytes against these retained files).
        "session-pet-states.json": "af4fc61df77344d955633563cef7b0c55fd7dc39a02753c443d26d9f16f4d134",
        "session-pet-attention-retime-v12-v1.png": "50edef0550ac04f8f388545ef072c125bafe75cccb1b3110b0f687440b8661ea",
        "session-pet-done-retime-v12-v1.png": "baf49d90057f7a44ef348f25a2dd7273b7bedaea80fdaee3ed53d5623f39dac1",
        "session-pet-duel-tail-tighter-v12-5.png": "074efb1f0ec6bbb489caaa31b803ec316e4bea1f783b33c7a97283358b5c3a61",
        "session-pet-error-reassembled-v12-v5.png": "e39b47f27e73b71ec3d70c9f14abfdcb30437a69a70cf3b07fc21e4ecf0abc34",
        "session-pet-idle-cutouts-v2.png": "f16814c7139b1d72009c755497f9e97b9100635c86cde123bbc232565ae6e33c",
        "session-pet-patrol-polish-v3.png": "c1340d57fd902522cc686664b225358b14a9d3246eada3e98221fbedd9efc4c6",
        "session-pet-swarm-alpha-v11-r2.png": "d9ff4d799890f03616e76bd492aa477ae36fd1a3bc26c03cc8683dbb7dc4ddc1",
        "session-pet-trio-deflect-eased-v12-6.png": "32f90389979a93d64455ffbf26defccb954436afb6c98d5140a2235404e44685",
        "session-pet-waiting-release-v1.png": "e885beb423f2e8febd348d0a8fc566ed2e20da6c1b78bbe33efc3a9aa6b765f3",
        "session-pet-working-run-slowed-v12-1.png": "b48d1eba464629eb393dcdc9be1c7f7bdb8d553339a53f542b758ee3cd98693b",
        # V14 timing-v2's four V13 strips, retained so the upgrade can recognize an installed V14 by its bytes. Its 27
        # cast layers no longer ship. Every V15 file, 1x and retina, is pinned by Tests/jedi-v15-pack-pins.py. The V12.6 map is the stock
        # history entry the upgrade recognizes; its V12.6 strips stay pinned above.
        "stock-state-history.json": "9623b2c1ed420bfcbc295631ca6aa0bebd97a9b4d4acbbb6444a448ac969d69e",
        "session-pet-working-v13.png": "4df56c59db80b8041de5a6f24a56eeadbaa26afca23be4af1c93b702ff5c2c52",
        "session-pet-duel-v13.png": "e0d1fc28f3eb8c89b74514687272d7290fe0a56577f14ee064f91f35af50b51d",
        "session-pet-trio-v13.png": "397e277d2c566ae9e8f418ec5af850420aeac1dd95f824beff1b6f330b1b0096",
        "session-pet-swarm-v13.png": "a9a16a873f6098219b9b5b26f8f9e9deebf4e33cb194e8e83a577ac2417186cd",
    }
    for file, expected_hash in approved_hashes.items():
        actual_hash = hashlib.sha256((root / "Resources/DefaultPet" / file).read_bytes()).hexdigest()
        need(actual_hash == expected_hash, f"approved or retained Miles story drifted: {file}")
    need(all((root / "Resources/DefaultPet" / name).is_file() for name in layers), "every V15 cast layer ships")
    # The stock maps the upgrade recognizes, byte for byte in content: V12.6 as 0.5.316 to 0.5.324 shipped it, and V14 in
    # both of its exact forms (0.5.328): flat as 0.5.325 to 0.5.327 shipped it, and as Miles installed it by hand.
    history = json.loads((root / "Resources/DefaultPet/stock-state-history.json").read_text())["maps"]
    need([hashlib.sha256((json.dumps(m["state"], indent=2) + "\n").encode()).hexdigest() for m in history]
         == ["37b7f0ec37be7daba1d369bd50c05ab2a07a07c0eb8289ae5216c7299b711d24",
             "5e8ed597530ea1372592f19b67b10108b2a854c988baa08429af0f73620888ca",
             "8016a0c9d9e804a21267cb9f41e23242180210d0cd2c6c696bd6ec74b3cbe08f"],
         "the stock history must hold V12.6 (37b7f0ec...), V14 flat (5e8ed597...) and V14 as installed (8016a0c9...)")

    playlist = models.split("var usesActivityPlaylist", 1)[1].split(
        "func spriteHeight", 1
    )[0]
    need(
        "case .patrol: true" in playlist
        and "case .working" not in playlist
        and "case .duel" not in playlist,
        "authored running/duel stories must bypass the ambient playlist",
    )
    rest_body = controller.split("func petRestClips(", 1)[1].split(
        "func setPetCharacterPercent", 1
    )[0]
    need(
        "PetSpriteStore.restPoses(for: pose, stateMap: petStateMap)" in rest_body
        and "exactFrames(for:" in rest_body,
        "patrol must use exact calm clips, never fallback-resolved art",
    )
    rest_selection = models.split("static func restPoses(", 1)[1].split("static func galleryThumbnail", 1)[0]
    need("guard pose == .patrol" in rest_selection
         and "[PetSpritePose.idle, .waiting]" in rest_selection
         and "seen.insert" in rest_selection,
         "ambient selection must deduplicate shared calm assets and preserve distinct rests")
    need(
        "case .working" not in rest_body and "case .duel" not in rest_body,
        "running/duel stories are still being spliced by the ambient scheduler",
    )
    need(
        "private var timelineInterval" in motion
        and "usableRestClips.map(\\.frameInterval)" in motion
        and ".min()" in motion,
        "the timeline does not tick at the fastest authored active clip",
    )
    need(
        "primaryFrameInterval" in motion
        and "interval: primaryFrameInterval" in motion
        and " / primaryFrameInterval" in motion,
        "a bundled character's authored cadence does not drive playback",
    )
    need(
        "visualScale" not in models and ".scaleEffect(" not in motion,
        "a global paint transform can still crop or resize arbitrary character packs",
    )
    need(
        "loadRenderScales" in models
        and "petRenderScales" in controller
        and "characterScale * model.petRenderScale(for: pose)" in pet,
        "pack-owned pose scaling is not wired through the live renderer",
    )
    need(
        "refreshRecognizedBundledDefault" in models
        and "BundledDefaultRefreshResult" in models
        and "installed.count == retainedStock.count" in models
        and "for pose in PetSpritePose.allCases where retainedStock[pose] != nil {" in models
        and "guard bundled.count == retainedStock.count else { return .failed }" in models
        and "updated[story.pose] = (story.file, story.frames)" in models
        and "            return .current\n" in models
        and int(re.search(r"petDefaultArtGeneration = (\d+)", controller).group(1)) >= 23
        and "if refresh != .failed" in controller,
        "installed stock Miles packs will not receive the whole V15 pack",
    )
    # The BODY of handleSpriteClick: toggleSessionMenu now sits between it and
    # handleSpriteDrop and legitimately names petExpanded. Two toggle sites are
    # expected as of 0.5.130 -- the chevron, and the double-click Miles asked
    # for. A SINGLE click still may not expand; that is the layout-shift rule.
    handle = pet.split("private func handleSpriteClick()", 1)[1].split("\n    }", 1)[0]
    # Owner-based, not count-based. The count was 2 only while the double-click
    # spelled its work as `.toggle()`; on 2026-09-01 it became a real
    # toggle-with-memory using explicit assignment, and three copies of this
    # check failed on the SHAPE while the RULE was intact.
    _exp_owners = set()
    for _m in re.finditer(r"model\.petExpanded(?:\.toggle\(\)|\s*=\s*true)", pet):
        _fn = None
        for _f in re.finditer(r"private (?:func|var) (\w+)", pet[:_m.start()]):
            _fn = _f.group(1)
        _exp_owners.add(_fn)
    need(
        "petExpanded" not in handle
        and _exp_owners == {"pillsRow", "toggleSessionMenu"},
        "a single character click can still expand sessions",
    )
    need(
        ".onTapGesture(count: 2) { toggleSessionMenu() }" in pet,
        "the double-click route into the session list is gone",
    )


def must_fail(
    name: str,
    root: pathlib.Path,
    models: str,
    controller: str,
    motion: str,
    pet: str,
) -> None:
    try:
        validate(root, models, controller, motion, pet)
    except ContractFailure:
        return
    raise AssertionError(f"mutation canary stayed green: {name}")


def main() -> None:
    root = pathlib.Path(sys.argv[1])
    models = (root / "Sources/Models.swift").read_text()
    controller = (root / "Sources/ControllerModel.swift").read_text()
    motion = (root / "Sources/COSMotion.swift").read_text()
    pet = (root / "Sources/SessionPet.swift").read_text()
    validate(root, models, controller, motion, pet)

    must_fail(
        "legacy 128-frame cap truncates illustrated stories",
        root, models.replace("static let maxFrames = 256", "static let maxFrames = 128"),
        controller, motion, pet,
    )

    must_fail(
        "old art generation strands installed 0.5.314 packs",
        root, models,
        re.sub(r"petDefaultArtGeneration = \d+", "petDefaultArtGeneration = 19", controller),
        motion, pet,
    )
    must_fail(
        "refresh promotes only the four stories again",
        root,
        models.replace("for pose in PetSpritePose.allCases where retainedStock[pose] != nil {",
                       "for pose in [PetSpritePose.working, .duel, .trio, .swarm] {", 1),
        controller, motion, pet,
    )

    must_fail(
        "fallback-resolved ambient art",
        root,
        models,
        controller.replace("exactFrames(for:", "frames(for:", 1),
        motion,
        pet,
    )
    must_fail(
        "timeline ignores secondary cadence",
        root,
        models,
        controller,
        motion.replace("usableRestClips.map(\\.frameInterval)", "[]", 1),
        pet,
    )
    scale_mutation = motion.replace(
        ".resizable()", ".resizable()\n            .scaleEffect(1.18)", 1
    )
    must_fail("hardcoded paint scale returns", root, models, controller, scale_mutation, pet)
    click_mutation = pet.replace(
        "private func handleSpriteClick() {",
        "private func handleSpriteClick() {\n        model.petExpanded.toggle()",
        1,
    )
    must_fail("character click expands sessions", root, models, controller, motion, click_mutation)
    print("COS Control: approved Version 15 Miles pack, 39 cast layers on four sessions, whole-pack refresh and chevron-only expansion passed")


if __name__ == "__main__":
    main()
