#!/usr/bin/env python3
"""Fast canary for the session-pet collapsed-layout contract."""

from pathlib import Path
import re
import sys


root = Path(sys.argv[1])
models = (root / "Sources/Models.swift").read_text()
controller = (root / "Sources/ControllerModel.swift").read_text()
pet = (root / "Sources/SessionPet.swift").read_text()


def need(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"pet layout: {message}")


need("let show = model.petEnabled\n" in pet,
     "enabled pets must stay visible with zero sessions")
need("viewportSize: CGSize" in pet and
     ".frame(width: viewportSize.width, height: viewportSize.height, alignment: .bottom)" in pet,
     "the character is not mounted in a stable collapsed viewport")
# Two toggle sites only: the chevron, and the double-click on the figure that
# Miles asked for on 2026-08-28. A SINGLE click still must not expand -- that is
# the cumulative-layout-shift rule the collapsed viewport exists to hold.
need(pet.count("model.petExpanded.toggle()") == 2,
     "expansion may be toggled only by the dropdown control and the double-click handler")
# The BODY of handleSpriteClick, not everything up to the next named function --
# toggleSessionMenu now sits between the two and legitimately names petExpanded.
handle = pet.split("private func handleSpriteClick()", 1)[1].split("\n    }", 1)[0]
need("petExpanded" not in handle,
     "a single click on the character must not expand the session list")
menu = pet.split("private func toggleSessionMenu()", 1)[1].split("\n    }", 1)[0]
need("guard sessions.count > 1 else { return }" in menu,
     "double-click must be inert when there is no list to show")
need(pet.index(".onTapGesture(count: 2)") < pet.index(".onTapGesture { handleSpriteClick() }"),
     "the double-click must be declared before the single tap or the single tap wins")
need("private var idleBubble" in pet and "private var petButtonPlaceholder" in pet,
     "zero/one-session chrome must reserve the collapsed layout slots")

apply_sessions = controller.split("private func applyPetSessions(", 1)[1]
apply_sessions = re.split(r"\n    (?:private )?func ", apply_sessions, maxsplit=1)[0]
need("petExpanded = true" not in apply_sessions and "previousCount < 2" not in apply_sessions,
     "a session-count transition must not auto-open the list")
need("if petSessions.count < 2" in apply_sessions and "petExpanded = false" in apply_sessions,
     "the list must close when fewer than two sessions remain")

sprite_height = models.split("func spriteHeight(", 1)[1].split("func spriteWidth(", 1)[0]
need("cinematic ?" not in sprite_height,
     "multi-session art must not grow above the solo pose height")
need("func viewportSize(" in models and "func fittedViewportScale(" in models,
     "the lifecycle-wide size/fit contract is missing")
need("static func resolvedAspect(frames:" in models and
     "PetSpriteKit.resolvedAspect(frames: frames)" in (root / "Sources/COSMotion.swift").read_text(),
     "parent and child do not share the square missing-frame aspect")

print("COS Control: stable pet viewport and dropdown-only expansion passed")
