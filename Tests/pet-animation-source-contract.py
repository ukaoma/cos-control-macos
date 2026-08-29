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
    state = json.loads((root / "Resources/DefaultPet/session-pet-states.json").read_text())["poses"]
    need(
        state["working"] == {"file": "session-pet-working-one-droid-v15.png", "frames": 16},
        "one session does not point at the run/brake/error/run story",
    )
    need(
        state["duel"] == {"file": "session-pet-duel-two-droid-v15.png", "frames": 13},
        "two sessions do not point at the run/brake/two-droid/run story",
    )
    need(
        state["trio"] == {"file": "session-pet-trio-story-v15.png", "frames": 13},
        "three sessions do not point at the rebuilt three-droid story",
    )
    need(
        state["swarm"] == {"file": "session-pet-swarm-story-v15.png", "frames": 16},
        "four-plus sessions do not point at the rebuilt five-droid story",
    )
    cell_widths = {"working": 304, "duel": 304, "trio": 286, "swarm": 311}
    for pose, cell_width in cell_widths.items():
        row = state[pose]
        width, height, color_type = png_header(root / "Resources/DefaultPet" / row["file"])
        need(width == cell_width * row["frames"] and height == 256,
             f"{pose} story canvas/frame declaration drifted")
        need(color_type == 6, f"{pose} story must be a true RGBA PNG")
    approved_hashes = {
        "session-pet-working-one-droid-v15.png": "c6f5f82d9147bf5ef66e88d9ffc0897cc06334c8f8378cc02edaac2d4796d97a",
        "session-pet-duel-two-droid-v15.png": "b83b1310878075e00f77062b0852a477461fc9d966d30aa104434f89e6b8bf3f",
        "session-pet-trio-story-v15.png": "0cf66752e7c282cbfb09cb8a96a9b3ef2d5f1029e0ce4f70076983f76ffc5682",
        "session-pet-swarm-story-v15.png": "d08b524f8e2997f8be4228a5dd15bb9ef3c5efee75a7963b3ffa9e2ac6128876",
    }
    for file, expected_hash in approved_hashes.items():
        actual_hash = hashlib.sha256((root / "Resources/DefaultPet" / file).read_bytes()).hexdigest()
        need(actual_hash == expected_hash, f"approved V15 story drifted: {file}")

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
        "case .patrol: [.idle, .waiting]" in rest_body
        and "exactFrames(for:" in rest_body,
        "patrol must use exact calm clips, never fallback-resolved art",
    )
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
        "visualScale" not in models and ".scaleEffect(" not in motion,
        "a global paint transform can still crop or resize arbitrary character packs",
    )
    need(
        "refreshRecognizedBundledDefault" in models
        and "BundledDefaultRefreshResult" in models
        and "installed.count == retainedStock.count" in models
        and "let storyPoses: [PetSpritePose] = [.working, .duel, .trio, .swarm]" in models
        and "updated[story.pose] = (story.file, story.frames)" in models
        and int(re.search(r"petDefaultArtGeneration = (\d+)", controller).group(1)) >= 5
        and "if refresh != .failed" in controller,
        "installed Miles packs will not receive all four new story assets",
    )
    # The BODY of handleSpriteClick: toggleSessionMenu now sits between it and
    # handleSpriteDrop and legitimately names petExpanded. Two toggle sites are
    # expected as of 0.5.130 -- the chevron, and the double-click Miles asked
    # for. A SINGLE click still may not expand; that is the layout-shift rule.
    handle = pet.split("private func handleSpriteClick()", 1)[1].split("\n    }", 1)[0]
    need(
        "petExpanded" not in handle and pet.count("model.petExpanded.toggle()") == 2,
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
    print("COS Control: four authored Miles stories and chevron-only expansion passed")


if __name__ == "__main__":
    main()
