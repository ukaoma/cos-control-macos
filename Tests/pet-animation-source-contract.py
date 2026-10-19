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
    # 0.5.325: Miles approved V14 timing-v2 (installation-v14-timing-v2, 2026-10-17) as the bundled pack: the V13
    # Session 1 to 4 strips and, on duel, trio and swarm, three shuffled casts. The source map is his approved
    # candidate-pack/session-pet-states.json (sha256 8016a0c9...) with each rotation layer renamed flat
    # (rotation/v14-timing-v2/X.png became session-pet-windu-v14-timing-v2-X.png, bytes identical; hashes pinned below)
    # because the release copies DefaultPet without subfolders. 0.5.316 to 0.5.324 shipped V12.6 (stock-state-history.json).
    approved_state = {
        "attention": {"file": "session-pet-attention-retime-v12-v1.png", "frames": 13, "interval": 0.14},
        "done": {"file": "session-pet-done-retime-v12-v1.png", "frames": 10, "interval": 0.16},
        "duel": {"file": "session-pet-duel-v13.png", "frames": 37, "interval": 0.08},
        "error": {"file": "session-pet-error-reassembled-v12-v5.png", "frames": 8, "interval": 0.14},
        "idle": {"file": "session-pet-idle-cutouts-v2.png", "frames": 8, "renderScale": 1.0},
        "patrol": {"file": "session-pet-patrol-polish-v3.png", "frames": 8, "interval": 0.14},
        "swarm": {"file": "session-pet-swarm-v13.png", "frames": 64, "interval": 0.08},
        "trio": {"file": "session-pet-trio-v13.png", "frames": 43, "interval": 0.08},
        "waiting": {"file": "session-pet-waiting-release-v1.png", "frames": 11, "interval": 0.18},
        "working": {"file": "session-pet-working-v13.png", "frames": 46, "interval": 0.08, "renderScale": 0.75},
    }
    raw_rows = json.loads((root / "Resources/DefaultPet/session-pet-states.json").read_text())["poses"]
    state = {pose: {k: v for k, v in row.items() if k != "rotation"} for pose, row in raw_rows.items()}
    need(sorted(p for p, row in raw_rows.items() if "rotation" in row) == ["duel", "swarm", "trio"],
         "V14 carries a three-cast rotation on duel, trio and swarm, and nowhere else")
    handoffs = {"duel": 28, "trio": 31, "swarm": 55}
    layers = []
    for pose, handoff in handoffs.items():
        rotation = raw_rows[pose]["rotation"]
        need(rotation["version"] == 1 and rotation["handoffFrame"] == handoff, f"{pose} cast handoff drifted")
        need([v["id"] for v in rotation["variants"]] == [f"{pose}-a", f"{pose}-b", f"{pose}-c"], f"{pose} casts drifted")
        strip_w, strip_h, _ = png_header(root / "Resources/DefaultPet" / raw_rows[pose]["file"])
        for variant in rotation["variants"]:
            for key, kind in (("file", "full"), ("bodyFile", "body"), ("entryFile", "entry")):
                name = variant[key]
                need(name == f"session-pet-windu-v14-timing-v2-{variant['id']}-{kind}.png" and "/" not in name,
                     f"{pose} layer {name} must be flat (the release copies DefaultPet without subfolders)")
                w, h, ct = png_header(root / "Resources/DefaultPet" / name)
                need((w, h, ct) == (strip_w, strip_h, 6), f"{name} must be an RGBA layer the size of its {pose} strip")
                layers.append(name)
    need(len(set(layers)) == 27, "27 distinct cast layers")
    for pose, row in approved_state.items():
        need(state.get(pose) == row, f"{pose} does not point at the approved V14 strip, count, cadence and scale")
    need(set(state) == set(approved_state), "the shipped Miles map has a pose V14 does not declare")
    frame_cap = int(re.search(r"static let maxFrames = (\d+)", models).group(1))
    need(frame_cap == 128, "runtime frame limit must preserve complete Jedi recovery and entrance frames")
    cell_widths = {"attention": 121, "done": 99, "duel": 304, "error": 224, "idle": 83, "patrol": 128,
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
        "session-pet-states.json": "5e8ed597530ea1372592f19b67b10108b2a854c988baa08429af0f73620888ca",
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
        # V14 timing-v2: the map as shipped (flat names), the V13 strips, and all 27 cast layers (same bytes as the
        # approved pack; its installation-receipt.json lists the layers under rotation/v14-timing-v2/). The V12.6 map
        # is the stock history entry the upgrade recognizes; its V12.6 strips stay pinned above.
        "stock-state-history.json": "7b278744f6b9075b19ab05e74878693e564f4459797cfcc6cf4bb0479eaf4341",
        "session-pet-working-v13.png": "4df56c59db80b8041de5a6f24a56eeadbaa26afca23be4af1c93b702ff5c2c52",
        "session-pet-duel-v13.png": "e0d1fc28f3eb8c89b74514687272d7290fe0a56577f14ee064f91f35af50b51d",
        "session-pet-trio-v13.png": "397e277d2c566ae9e8f418ec5af850420aeac1dd95f824beff1b6f330b1b0096",
        "session-pet-swarm-v13.png": "a9a16a873f6098219b9b5b26f8f9e9deebf4e33cb194e8e83a577ac2417186cd",
        "session-pet-windu-v14-timing-v2-duel-a-body.png": "a565f3d631840ff4a8045c2d8676b66e896e6a29a2141f00b808ad5e3a59b9c0",
        "session-pet-windu-v14-timing-v2-duel-a-entry.png": "70455061eb306e335d4a9d186967e617c7803e38829b856ee5118b614b000d25",
        "session-pet-windu-v14-timing-v2-duel-a-full.png": "7fc390e1141ec5831bf2c6e57c31f7961c2d298ff4571dae9236b9a80f3868b7",
        "session-pet-windu-v14-timing-v2-duel-b-body.png": "34d73471731cd8ee44716fed2821535b6d5d56940bfef166059c9571b4fe950f",
        "session-pet-windu-v14-timing-v2-duel-b-entry.png": "720c1a62b3933f5a999222c0fad3380a3eb6b195b2f0d80ea0b4a64be5c00c8e",
        "session-pet-windu-v14-timing-v2-duel-b-full.png": "fbc00ee6b24b43125107ceb077a11baf7f890319db8a660d4c7d14b930fad1a6",
        "session-pet-windu-v14-timing-v2-duel-c-body.png": "61d4d452c0c30ff2e602829ee25a3d888df8faab46f2a9e3d3e34fc5e6ebd3df",
        "session-pet-windu-v14-timing-v2-duel-c-entry.png": "06b48149d35469a9608c2602713460a662eae11292503799b3a079bdb166cb23",
        "session-pet-windu-v14-timing-v2-duel-c-full.png": "3cb851554e2ecc1ecf77c14f8f1f6892258e477b299f53bce25b7be5d2213295",
        "session-pet-windu-v14-timing-v2-swarm-a-body.png": "0098e6085ecd1c6b138c8f8d7624f6a008a57aa48c979c43e8749fec127b28f1",
        "session-pet-windu-v14-timing-v2-swarm-a-entry.png": "fdb23ca8ead720c3e34ec3487cd4ff9b789a53ddf0df136e7d9dee944e4c0bb8",
        "session-pet-windu-v14-timing-v2-swarm-a-full.png": "1a500684f9a9d692e7bad7b958f01ff6e58826b1e779b6a0220885bf9ed8131a",
        "session-pet-windu-v14-timing-v2-swarm-b-body.png": "df8ca72dbb86dfe7b6442a41754c698f2b58736cd2043244980e40a3de6d9f87",
        "session-pet-windu-v14-timing-v2-swarm-b-entry.png": "87e5349da6cbeab631a35095fd3aa49b6dcaa899af9ee3dba7ab29040e60ac2f",
        "session-pet-windu-v14-timing-v2-swarm-b-full.png": "092264f1d43fe81b774bdd5b6d43fae5ba67a9e579a1091c2c1aaac875893575",
        "session-pet-windu-v14-timing-v2-swarm-c-body.png": "4e21a51105f8d624e609136ee6381262c8eba529124e83fb0b09f758ca7f15d1",
        "session-pet-windu-v14-timing-v2-swarm-c-entry.png": "b3e8fe9c5a496bb8852e847cc0cc8830b8c15b66e4909567817420de483c9d12",
        "session-pet-windu-v14-timing-v2-swarm-c-full.png": "ac80c6a4cc583d1b84765b82db8c993c5b3c4c2a528077e59fb7cfa5e26cfe16",
        "session-pet-windu-v14-timing-v2-trio-a-body.png": "b0f646ac9db843aadf4122ea1690e39ae9c532d80d05fcb7ad3f8a8df9162d9f",
        "session-pet-windu-v14-timing-v2-trio-a-entry.png": "11ccec8924ade25214c2f0548e6dfc64a008de012b07bb707cb21e881802f9db",
        "session-pet-windu-v14-timing-v2-trio-a-full.png": "791ce5210f4a6f8ea28cb28d0285dfe704779522f615c906716d134ba9915b69",
        "session-pet-windu-v14-timing-v2-trio-b-body.png": "b63ff686279353dfa1633cb8357afdf1dfb029624424cd3df0e4559928a34990",
        "session-pet-windu-v14-timing-v2-trio-b-entry.png": "48007d101ea4bc2360f5e5925458dad07356d114f41d4e03cf724e7ee3713282",
        "session-pet-windu-v14-timing-v2-trio-b-full.png": "d08650c8e8d624f424a77b7949864ce4a11784c4c7149ed5ef2bbc016d3a37da",
        "session-pet-windu-v14-timing-v2-trio-c-body.png": "a689774b2c54df27921a242b79f08e7bd3309dc5c6b1091308e948a989fa49a2",
        "session-pet-windu-v14-timing-v2-trio-c-entry.png": "e714b02bc47fb802fc1d2817b4c24d620b70b6a1b12392ec1513f29390be07ca",
        "session-pet-windu-v14-timing-v2-trio-c-full.png": "1913f4cdcfee07d3bb50ecaeb3481990b17505c8bfd7ae846a94aa5eb6ee5a63",
    }
    for file, expected_hash in approved_hashes.items():
        actual_hash = hashlib.sha256((root / "Resources/DefaultPet" / file).read_bytes()).hexdigest()
        need(actual_hash == expected_hash, f"approved or retained Miles story drifted: {file}")
    need(set(layers) <= set(approved_hashes), "every V14 cast layer has a pinned hash")
    # The stock V12.6 map the upgrade recognizes is the 0.5.316 to 0.5.324 shipped map, byte for byte in content.
    history = json.loads((root / "Resources/DefaultPet/stock-state-history.json").read_text())["maps"]
    need(len(history) == 1 and hashlib.sha256((json.dumps(history[0]["state"], indent=2) + "\n").encode()).hexdigest()
         == "37b7f0ec37be7daba1d369bd50c05ab2a07a07c0eb8289ae5216c7299b711d24",
         "the stock history must hold the shipped V12.6 map (sha256 37b7f0ec...)")

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
        and int(re.search(r"petDefaultArtGeneration = (\d+)", controller).group(1)) >= 20
        and "if refresh != .failed" in controller,
        "installed stock Miles packs will not receive the whole V14 pack",
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
        "sixteen-frame cap truncates longer stories",
        root, models.replace("static let maxFrames = 128", "static let maxFrames = 32"),
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
    print("COS Control: approved Miles V14 timing-v2 pack, 27 pinned cast layers, whole-pack refresh and chevron-only expansion passed")


if __name__ == "__main__":
    main()
