#!/usr/bin/env python3
"""0.5.352: the pet's drag path exists and is wired. Tests/PetDragChecks.swift covers the tracker's behaviour; this
pins that PetPanel routes the left button through it, moves the frame on `.move`, keeps the drag's release from being
a tap, and marks the pills, lists and cards as surfaces a drag may not start from."""
import re, sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
pet = (root / "Sources/SessionPet.swift").read_text()
passed = 0

def need(ok, why):
    global passed
    if not ok:
        sys.exit(f"FAIL: {why}")
    passed += 1

def body(src, start):
    rest = src[src.index(start):]
    return rest[:rest.index("\n    }\n") + 6]

need("panel.isMovableByWindowBackground = false" in pet and "isMovableByWindowBackground = true" not in pet,
     "the pet relies on isMovableByWindowBackground again; on macOS 27.2 it never starts a drag")
panel = pet[pet.index("final class PetPanel: NSPanel {"):pet.index("struct PetNoDragZone")]
send = body(panel, "override func sendEvent(_ event: NSEvent) {")
need("drag.mouseDown(" in send and "mayDrag: !event.modifierFlags.contains(.control) && !pressIsInNoDragZone(event)" in send,
     "PetPanel no longer arms the drag on a press, or arms it on control-click or a pill")
need(re.search(r"case \.move\(let origin\) = drag\.mouseDragged\(mouse: NSEvent\.mouseLocation\)\s*\{\s*setFrameOrigin\(origin\)\s*return", send),
     "a drag past the threshold no longer moves the panel")
need(re.search(r"if drag\.mouseUp\(\) \{.*?return\s*\}", send, re.S),
     "a drag's release reaches SwiftUI where it was pressed and opens the session as a tap")
need(send.rstrip().endswith("super.sendEvent(event)\n    }"),
     "PetPanel swallows events it does not handle; clicks and the right-click menu need them")
for handler in ("private func handleSpriteClick() {", "private func toggleSessionMenu() {"):
    first = pet[pet.index(handler):].split("\n", 2)[1].strip()
    need(first == "guard presenter.consumeSpriteTap() else { return }",
         f"{handler} acts on the tap that ends a drag")
need("func consumeSpriteTap() -> Bool { (panel as? PetPanel)?.consumeTap() ?? true }" in pet,
     "the presenter no longer asks the panel whether a tap followed a drag")
zone = pet[pet.index("struct PetNoDragZone"):]
need("override func hitTest(_ point: NSPoint) -> NSView? { nil }" in zone[:zone.index("func makeNSView")],
     "a no-drag zone takes clicks from the control it sits behind")
for surface in ("sessionList\n", "completionsList\n", "dictationList(route)\n",
                "DictationCardView(store: dictation, card: card, size: size, reduceMotion: reduceMotion)\n",
                "MeetingCardView(store: meetings, card: card, size: size)\n", "composerCard(target)\n"):
    after = pet[pet.index(surface):].split("\n", 2)[1].strip()
    need(after == ".background(PetNoDragZone())", f"{surface.strip()} can start a drag; its rows and buttons need the press")
need(".background(PetNoDragZone(active: showPills || listening))" in body(pet, "private var ledgerSlot"),
     "the pills can start a drag, or the resting ledger bar cannot")
print(f"COS Control: pet drag source contract, {passed} checks passed")
