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
# Expansion has exactly TWO owners: the pills (the RUNNING pill from 0.5.142,
# which replaced the chevron, plus WAITING opening the list to choose) and the
# double-click on the figure Miles asked for on 2026-08-28. A SINGLE click must
# still never expand -- that is the cumulative-layout-shift rule the collapsed
# viewport exists to hold.
#
# This used to count `model.petExpanded.toggle()` == 2. That pinned the SHAPE
# rather than the rule, and broke on 2026-09-01 when the double-click became a
# real toggle-with-memory using explicit assignment. Assert the OWNERS instead,
# so the rule survives the next rewrite of either handler.
import re as _re
_owners = {}
for _m in _re.finditer(r"model\.petExpanded(?:\.toggle\(\)|\s*=\s*true)", pet):
    _fn = None
    for _f in _re.finditer(r"private (?:func|var) (\w+)", pet[:_m.start()]):
        _fn = _f.group(1)
    _owners.setdefault(_fn, 0)
    _owners[_fn] += 1
need(set(_owners) == {"pillsRow", "toggleSessionMenu"},
     f"the running list can be expanded from {sorted(_owners)}; only the pills "
     "and the figure's double-click may expand it")
# A single click jumps to the platform; it must never expand.
_single = pet[pet.index("private func handleSpriteClick"):]
_single = _single[:_single.index("\n    }")]
need("petExpanded" not in _single and "petCompletionsExpanded" not in _single,
     "a SINGLE click now changes expansion; that is the layout-shift rule the "
     "collapsed viewport exists to hold")
# The BODY of handleSpriteClick, not everything up to the next named function --
# toggleSessionMenu now sits between the two and legitimately names petExpanded.
handle = pet.split("private func handleSpriteClick()", 1)[1].split("\n    }", 1)[0]
need("petExpanded" not in handle,
     "a single click on the character must not expand the session list")
menu = pet.split("private func toggleSessionMenu()", 1)[1].split("\n    }", 1)[0]
# The rule is "inert when there is NOTHING to show". It used to be spelled
# `guard sessions.count > 1`, which is a different and wrong thing: it was also
# inert at exactly ONE running session, which is a list worth showing, so the
# gesture silently died in the most common case (Miles, 2026-09-01, at
# RUNNING 1). The literal was pinned here, so the test defended the bug.
need("sessions.count > 1" not in menu,
     "double-click gates on a session count again; at RUNNING 1 the gesture "
     "silently does nothing")
need("isEmpty" in menu,
     "double-click no longer checks whether either list has content, so it can "
     "open an empty card over the figure")
need(pet.index(".onTapGesture(count: 2)") < pet.index(".onTapGesture { handleSpriteClick() }"),
     "the double-click must be declared before the single tap or the single tap wins")
# 0.5.142 ledger design: the reserved-slot rule MOVED, it did not die. Idle
# chrome is the fixed-height ledger; the pills cross-fade into that SAME slot,
# so nothing above the sprite ever changes size on hover — the whole reason
# the prototype's first hover was rejected as jumpy.
need("private var ledgerSlot" in pet, "the ledger slot is gone")
ledger_slot = pet[pet.index("private var ledgerSlot"):pet.index("private func ledgerBar")]
need(".frame(height:" in ledger_slot and "maxHeight" not in ledger_slot,
     "the ledger slot must be FIXED height — hover must never resize above the sprite")
need("idleBubble" not in pet and "petButtonPlaceholder" not in pet,
     "pre-ledger idle chrome must not survive alongside the bar")
# Completion chips (0.5.141): the finished list has its own expansion flag and
# never rides the live list's expansion. (The duplicate toggle-COUNT assertion
# that used to sit here is superseded by the owner-based check further up; two
# copies of the same rule failed independently on 2026-09-01 when only the
# spelling changed.)
need("petCompletionsExpanded" in pet and "petExpanded" in pet,
     "the finished list lost its own expansion flag and now rides the live list")
need("petCompletionsExpanded" in pet, "the finished-list flag is gone")
comp = pet[pet.index("private var completionsList"):pet.index("private var spriteHelp")]
need("ScrollView" in comp and ".frame(height:" in comp and "maxHeight" not in comp
     and "petExpanded.toggle" not in comp,
     "the finished list must scroll in a FIXED frame (maxHeight collapses under "
     "sizeThatFits) and not toggle the live list")

apply_sessions = controller.split("private func applyPetSessions(", 1)[1]
apply_sessions = re.split(r"\n    (?:private )?func ", apply_sessions, maxsplit=1)[0]
need("petExpanded = true" not in apply_sessions and "previousCount < 2" not in apply_sessions,
     "a session-count transition must not auto-open the list")
# 0.5.150: the RUNNING pill legitimately opens a ONE-row list (dismiss and
# restore live there), so the poll may close it only when it is truly empty —
# the old <2 threshold shut the list under the cursor within one 20s poll.
need("if petSessions.isEmpty && petDismissals.stamps.isEmpty" in apply_sessions
     and "petSessions.count < 2" not in apply_sessions,
     "the live list must auto-close only when there is nothing left to show — "
     "dismissal stamps keep the restore row reachable")

sprite_height = models.split("func spriteHeight(", 1)[1].split("func spriteWidth(", 1)[0]
need("cinematic ?" not in sprite_height,
     "multi-session art must not grow above the solo pose height")
need("func viewportSize(" in models and "func fittedViewportScale(" in models,
     "the lifecycle-wide size/fit contract is missing")
need("static func resolvedAspect(frames:" in models and
     "PetSpriteKit.resolvedAspect(frames: frames)" in (root / "Sources/COSMotion.swift").read_text(),
     "parent and child do not share the square missing-frame aspect")

print("COS Control: stable pet viewport and dropdown-only expansion passed")
