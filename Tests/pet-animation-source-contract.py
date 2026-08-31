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
        state["working"] == {
            "file": "session-pet-working-one-droid-v15-2.png", "frames": 16, "interval": 0.1
        },
        "one session does not point at the run/brake/error/run story",
    )
    need(
        state["duel"] == {
            "file": "session-pet-duel-two-droid-v15-2.png", "frames": 17,
            "interval": 0.11,
        },
        "two sessions do not point at the run/brake/two-droid/run story",
    )
    need(
        state["trio"] == {
            "file": "session-pet-trio-story-v15-2.png", "frames": 13, "interval": 0.22
        },
        "three sessions do not point at the rebuilt three-droid story",
    )
    need(
        state["swarm"] == {
            "file": "session-pet-swarm-story-v15-4.png", "frames": 26, "interval": 0.22
        },
        "four-plus sessions do not point at the rebuilt five-droid story",
    )
    need(state["idle"].get("renderScale") == 1.3, "Miles idle is not authored at 1.30x scale")
    frame_cap = int(re.search(r"static let maxFrames = (\d+)", models).group(1))
    need(frame_cap == 32, "runtime frame limit must preserve longer authored stories")
    cell_widths = {"working": 304, "duel": 304, "trio": 286, "swarm": 311}
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
    }
    for file, expected_hash in approved_hashes.items():
        actual_hash = hashlib.sha256((root / "Resources/DefaultPet" / file).read_bytes()).hexdigest()
        need(actual_hash == expected_hash, f"approved or retained Miles story drifted: {file}")

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
        and "let storyPoses: [PetSpritePose] = [.working, .duel, .trio, .swarm]" in models
        and "updated[story.pose] = (story.file, story.frames)" in models
        and int(re.search(r"petDefaultArtGeneration = (\d+)", controller).group(1)) >= 14
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
        "sixteen-frame cap truncates longer stories",
        root, models.replace("static let maxFrames = 32", "static let maxFrames = 16"),
        controller, motion, pet,
    )

    must_fail(
        "old art generation strands installed V15.3 packs",
        root, models,
        re.sub(r"petDefaultArtGeneration = \d+", "petDefaultArtGeneration = 13", controller),
        motion, pet,
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
    print("COS Control: four authored Miles stories and chevron-only expansion passed")


if __name__ == "__main__":
    main()
